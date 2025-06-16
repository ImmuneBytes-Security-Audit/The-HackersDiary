# **The Hacker’s Diary — Entry \#42**

### **Liquidate Thyself and Walk Away \- Euler Finance hit of 13 March 2023**

## **1\. Scene-setting:**

* **Protocol**  
  * Euler Finance lending market (main-net)  
* **Block height**   
  * 16 822 133  
* **Primary attacker EOAs**  
  * `0xb66cd966670d962c227b3eaba30a872dbfb995db`  
  * `0xb2698c2d99ad2c302a95a8db26b08d17a77cedd4`  
* **Main exploit contract**   
  * **Violator**: `0xeBC29199C817Dc47BA12E3F86102564D640CBf99`  
* **Exploit transaction**  
  * `0xc310a0affe2169d1f6feec1c63dbc7f7c62a887fa48795d327d4d2da2d6b111d`  
* **Total haul:** $197 000 000 across DAI, wBTC, wstETH, USDC

### **Dawn of the Exploit**

At 08:50:59 UTC the transaction with hash `0xc310a0affe2169d1f6feec1c63dbc7f7c62a887fa48795d327d4d2da2d6b111d`  
landed in block 16 822 133\. A single externally-owned account `0xb66cd966670d962c227b3eaba30a872dbfb995db` borrowed 30M DAI from Aave, steered it straight into Euler’s lending pools, and walked back out with collateral worth roughly 197M USD. Newsrooms would later summarise it as a flash-loan attack. 

Kinda true, but that label hides the most important fact: the thief did not game an oracle, nor slip through a re-entrancy door. They simply used a public function Euler had added seven months earlier, `donateToReserves()`and relied on Euler’s own liquidation engine to finish the job.

## **2\. Vulnerability autopsy:**

### **A Quick Tour of the Machine Breakdown**

Euler lets anyone deposit an asset and receive an eToken (their claim on the pool). Against that collateral a user may borrow, receiving a dToken that grows with interest. Because both tokens are ERC-20s, a user can recursively lend to themselves: deposit, borrow, deposit the borrow, and so on, multiplying exposure roughly 19-fold. Euler’s risk engine tracks a health-factor; if it ever dips below 1 the account is fair game for liquidation at a hefty discount.

In July 2022 governance merged a pull-request EIP-14. It introduced `donateToReserves()`, intended as a goodwill button: a whale could burn some of its collateral, fattening reserves for everybody else. The function burnt eTokens and added the same quantity to an internal `reserves` counter, but, fatally, it did not call `checkLiquidity()` after the burn. If a highly leveraged user pressed that button the engine kept believing the account was solvent until the very next instruction, at which point liquidation became legal. Omniscia’s post-mortem called it “bad debt created by omission.” 

The seemingly innocent and a method of goodwill, `donateToReserves()` burnt eTokens without refreshing the donor’s health factor:

```
function donateToReserves(uint subAccountId, uint amount)
    external nonReentrant
{
    _burn(msg.sender, amount);      // eTokens destroyed
    reserves += amount;             // protocol feels richer
    // ❌  Missing: checkLiquidity(msg.sender);
}
```

* By letting someone erase collateral while leaving debt intact, the function can push their health-score \< 1 in the same tx.  
* Euler’s soft-liquidation engine happily allows anyone to liquidate an under-collateralised address at up to a 20 % discount.  
* Throw in a flash-loan and you can be both sinner and saviour in one block. 

## **3\. Field notes:**

### **An Hour in the Life of a Flash-Loan Raider**

Writing as the attacker, my notebook for that morning focused the block number \[16 822 133\], (here the times are block-level, not wall-clock):

**T – 00 s** – pull 30 000 000 DAI from Aave V2, pay only the nine-base-point fee if I settle inside the same block.  
**T + 03 s** – deposit 20 000 000 DAI to Euler; receive 19 568 124 eDAI.  
**T + 07 s** – loop: borrow 195 681 244 DAI, redeposit, borrow again, ten passes. Health-factor floating at 1.02—perfectly legal.  
**T + 10 s** – press `donateToReserves(100 000 000 eDAI)`. Health-factor slams to 0.77. Alarms silent; function doesn’t check.  
**T + 11 s** – trigger liquidation from helper contract `0xb2698c2d99ad2c302a95a8db26b08d17a77cedd4`, buying my own bad debt at a seventeen-percent discount.  
**T + 20 s** – withdraw seized collateral (DAI, wBTC, wstETH, USDC), repay the Aave loan plus fee, net profit ≈ 8 900 000 DAI on this asset; repeat pattern on the other four pools before miners notice.  
**T + 90 s** – empty wallet balances into Tornado Cash and wait for the news cycle.

The single donation tipped the scales; everything else was mechanical liquidation and accounting drift. No oracle spike, no re-entrancy, no governance delay—just protocol logic weaponised against itself. BlockSec’s Phalcon dashboard raised the exploit flag within minutes, but the transaction had already been finalized. 

## **4\. Laboratory reconstruction:**

Goal: Prove that removing one `require` allows liquidation of your own debt for instant profit.

### **4.1 Fork & accounts**

* Fork main-net at block 16 822 130 (three blocks before the hit) so state matches pre-exploit.  
* Impersonate EOA `0xb66cd966670d962c227b3eaba30a872dbfb995db` to preserve on-chain allowances and nonce order.

### **4.2 Flash-loan stub**

Using Balancer’s Vault because its single-asset flash-loan is one call; we only need wstETH once:

```
IERC20[] tokens;
tokens[0] = IERC20(DAI);

uint256[] amounts;
amounts[0] = 30_000_000 ether;

vault.flashLoan(this, tokens, amounts, "");
```

### **4.3 Attack flow inside `receiveFlashLoan`**

1. Deposit 20 000 000 DAI.  
2. Mint `eToken::mint` × 10 to reach \> 400 M eDAI.  
3. Drop 100 000 000 eDAI via `donateToReserves` (the vulnerable call).  
4. Trigger liquidation by calling Euler’s `liquidate()` from a helper contract that we pre-deploy; it needs a separate address so the protocol sees two parties.  
5. Withdraw seized collateral,   
   1. repay flash-loan,   
   2. assert `DAI.balanceOf(attacker) > 8_000_000 ether`.

### **4.4 Assertion set**

```
assertGt( IERC20(DAI).balanceOf(address(this)),
          8_000_000 ether, // conservative lower bound
          "profit too small - exploit failed");
assertEq( EToken(eDAI).balanceOf(address(this)),
          0,
          "all collateral withdrawn");
```

The invariant we care about: profitability ≥ 8 M DAI and no residual debt—the same conditions met on-chain.

## **5\. Why the PoC chose these exact numbers:**

* **20 M / 30 M split** mirrors the real flash-loan so health-score math lines up with historical prices.  
* **10× mint loop** is Euler’s documented leverage ceiling for self-collateral positions.  
* **100 M eDAI donation** nudges health-score just below 1; donate more and the subsequent liquidation discount shrinks.  
* **8 M DAI assertion** leaves wiggle-room for gas costs in local forks (Foundry forks sometimes over-estimate reserves by a few wei).

## **6\. What should have stopped it:**

1. **Solvency re-check inside `donateToReserves`** —   
   1. Literally one `require(health >= 1)` would have reverted the donation.  
2. **Invariant fuzz tests** asserting totalCollateral ≥ totalDebt after every external call.   
   1. A single 30-second Echidna run flags the donor path immediately.  
3. **Dynamic leverage throttling** — cap recursive `mint` depth per block; the attacker needed nine loops before donation.  
4. **Real-time circuit breaker** wired to monitoring (BlockSec Phalcon raised the alert within minutes) that pauses liquidation when bad-debt spikes by \> x %.

## **7\. Closing page:**

Permissions that look harmless (“burn my own collateral, help the protocol\!”) can be deadlier than exotic re-entrancy. If a function changes a user’s balance, always recompute solvency at the end of the same call—no exceptions, no sacred cows.

**References**

(Block numbers, tx hashes, code repos and analyses referenced throughout)

* Chainalysis flash-loan post-mortem [chainalysis.com](https://www.chainalysis.com/blog/euler-finance-flash-loan-attack/)  
* BlockSec incident timeline and tweet thread [blocksec.com](https://blocksec.com/blog/euler-finance-incident-the-largest-hack-of-2023)  
* CertiK incident analysis [certik.com](https://www.certik.com/resources/blog/4iSrYY6HoaYxk1aKyjFb5v-euler-finance-incident-analysis)  
* SlowMist deep-dive [slowmist.medium.com](https://slowmist.medium.com/slowmist-an-analysis-of-the-attack-on-euler-finance-5143abc0d5ad)  
* Cyfrin step-by-step exploit breakdown [cyfrin.io](https://www.cyfrin.io/blog/how-did-the-euler-finance-hack-happen-hack-analysis)  
* Etherscan chat-embedded tx `0x539c6f…` [etherscan.io](https://etherscan.io/tx/0x539c6fff0fce70e02dddd80a5534acf3df57deafbdc40f41abb20aa8f94a6d0d)  
* SunWeb3Sec’s Reproducible PoC  [github.com](https://github.com/SunWeb3Sec/DeFiHackLabs/blob/main/past/2023/README.md#20230313---eulerfinance---business-logic-flaw)  
* CoinTelegraph coverage of the hack and recovery [cointelegraph.com](https://cointelegraph.com/news/euler-finance-attack-how-it-happened-and-what-can-be-learned?utm_source=chatgpt.com)

*Diary closed—until the next breach.*
