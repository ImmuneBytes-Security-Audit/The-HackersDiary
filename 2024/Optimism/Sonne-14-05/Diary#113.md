# **The Hacker’s Diary — Entry \#113**

### **"Flash, Inflate, Borrow": Sonne Finance’s $20 M Precision‑Loss Heist (14 May 2024\)**

## **Scene‑Setting**

* **Protocol**  
  * Sonne Finance lending market (Optimism main‑net)  
* **Block height**   
  * 120 062 493  
* **Primary attacker EOAs**  
  * `0x5d0d99e9886581ff8fcb01f35804317f5ed80bbb`  
  * `0xae4a7cde7c99fb98b0d5fa414aa40f0300531f43`  
* **Main exploit contract**   
  * `0xa78aefd483ce3919c0ad55c8a2e5c97cbac1caf8`  
  * `0x02fa2625825917e9b1f8346a465de1bbc150c5b9`  
* **Exploit transactions**  
  * `0x45c0ccfd3ca1b4a937feebcb0f5a166c409c9e403070808835d41da40732db96`  
  * `0x9312ae377d7ebdf3c7c3a86f80514878deb5df51aad38b6191d55db53e42b7f0`  
* **Total haul:**   
  * ≈ 20 000 000 USD (USDC \+ WETH \+ VELO)

### **Dawn of the Exploit**

At **19 : 56 : 41 UTC** the first of two exploit transactions hit Optimism block 120 062 493. In a single round‑trip the attacker borrowed **35.4 M VELO**, manipulated the exchange‑rate of the freshly listed **soVELO** market, then used two micro‑wei of soVELO to borrow **7.6 M USDC** and **265 WETH** from Sonne’s other pools. The second transaction repeated the pattern, draining the remainder. Sonne froze the protocol within thirty minutes, but the vaults were already empty.

## **Vulnerability Autopsy** 

Sonne is a Compound v2 fork. Each lending market tracks an **exchange rate**:

```
  exchangeRate \= (cash \+ borrows − reserves) / totalSupply
```

When a new market launches `totalSupply` is zero. Compound avoids divide‑by‑zero by seeding the market with an arbitrary **initialExchangeRate \= 0.02 e18** and printing the same amount of cTokens. Unfortunately, the **`redeemUnderlying`** code path later *rounds down* the required cTokens:

```
  uint256 exchangeRate \= exchangeRateStored();    // huge after inflation  
  uint256 tokensNeeded \= (amount \* 1e18) / exchangeRate;  
  // ↳ truncates toward zero
```

If `exchangeRate` is inflated enough, `tokensNeeded` falls *below 1 wei* and is truncated to **zero**, letting an attacker redeem assets for free. The trick is to keep **`totalSupply = 2 wei`** while shoving millions into `cash`.

## **Field Notes**

1. **Flash‑swap** 35 469 150 VELO from Velodrome V2 pair.  
2. **Mint** exactly **2 wei** of soVELO ( ≈ 400 000 001 velo‑wei ) to create a microscopic `totalSupply`.  
3. **Donate** the borrowed VELO directly to the soVELO contract. `cash` skyrockets; `totalSupply` stays 2\. New `exchangeRate ≈ 1 VEL 1e25`.  
4. **Enter markets** soVELO \+ soUSDC; the two‑wei position is now recognised as collateral worth \~35 M VELO.  
5. **Borrow** 768 947 220 961 USDC‑wei (≈ 7.6 M USDC) and 265 WETH.  
6. **RedeemUnderlying** all VELO by paying **1 wei soVELO** (round‑down\!), retrieve the 35 M donated VELO.  
7. **Repay** flash‑swap, walk away with ≈ $20 M of assets.

A single rounding bug, compounded by an empty pool, printed effectively infinite collateral out of thin air.

## **Laboratory Reconstruction (Foundry PoC)**

*Fork*: Optimism block 120 062 492.

1. **`LeverageMinter`** clones the attacker’s contract: mints 2 wei soVELO, transfers flash‑loaned VELO to soVELO.  
2. **`CollateralBorrower`** enters markets, borrows USDC \+ WETH, redeems VELO for 1 wei soVELO.  
3. Test asserts final profit `> 19_500_000 * 1e6` in USDC‑equivalent.

The full PoC lives in **`Sonne‑14‑05.t.sol`** (see sibling file).

## **Why These Magic Numbers?**

* **400 000 001 velo‑wei → 2 wei soVELO**: smallest mint that clears internal `MIN_MINT_AMOUNT`, preserving tiny `totalSupply`.  
* **35.4 M VELO flash‑swap**: mirrors on‑chain amount; inflates `cash / totalSupply` to \> 1e25, plenty to zero‑truncate `tokensNeeded`.  
* **Borrow 7.6 M USDC \+ 265 WETH**: exact amounts visible in transaction `0x9312ae…b7f0`.

Altering any figure by more than 1 % breaks the exchange‑rate geometry and the redeem‑rounding edge case.

## **Mitigation Checklist**

* **Seed new markets with \> 1e18 cTokens** so rounding never reaches zero.  
* **Use full‑precision math** (`mulWad`, `divWad`) or 128‑bit fixed‑point to prevent dangerous truncation.  
* **Block direct token donations**: require `msg.sender` to mint cTokens when transferring underlying.  
* **Invariant fuzz**: `redeemUnderlying(amount)` should never allow withdrawing more than the account supplied.

## **Closing Page — “What You Should Worry About More Than You Do”**

Every new market is born empty. Until liquidity trickles in, its maths lives on a knife‑edge where precision loss turns $1 of collateral into $10 000 000\. If your fork inherits Compound’s rounding, assume the first depositor is your adversary—and price the risk accordingly.

*Diary entry closed — until the next rounding error.*
