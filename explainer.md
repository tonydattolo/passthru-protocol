### **Decentralized Mortgage & MBS Platform – Smart-Contract-Only Overview**

This “office-hours” summary strips out business, legal, and front-end specifics and focuses **only** on how the core contracts interact on-chain.

---

#### 1 Key Contracts

| Contract | Purpose (one-liner) |
|----------|--------------------|
| **MortgageRouter** | Single front-door that orchestrates funding, payments, securitisation, and redemptions. |
| **MortgageNFT (ERC-721)** | Non-fungible token that encodes a single, fully-funded mortgage. |
| **MBSPool (ERC-1155)** | Holds MortgageNFTs and mints tranched *MBS* tokens (AAA / BBB / Equity). Also tracks losses & waterfall. |
| **MBSHook (Uniswap V4)** | Custom hook that prices MBS tokens inside their V4 pools using oracle data and blocks unauthorised pools. |
| **Oracle** | Pushes off-chain loan-performance & rate data on-chain for the hook and pool. |

---

#### 2 Happy-Path Flow (four steps)


1. **Origination / Funding**  
   `fundMortgage()`  
   - Lender sends USDC → Router  
   - Router mints **MortgageNFT** to lender

2. **Securitisation**  
   `securitiseMortgage()`  
   - Lender deposits MortgageNFT into **MBSPool**  
   - Pool burns NFT, mints tranched **MBS tokens** back to the lender

3. **Servicing**  
   `makePayment()` (called by borrower)  
   - Router receives USDC, skims a servicing fee, then calls `MBSPool.distribute()`  
   - Pool donates USDC directly to the correct Uniswap V4 pool in tranche order (AAA → BBB → Equity)

4. **Secondary Trading**  
   - Anyone can trade tranche tokens in a V4 pool that has **MBSHook** attached  
   - On each swap `beforeSwap()` asks the **Oracle** for fair value, returns deltas, pool enforces price  
   - Hook reverts interaction if the pool isn’t whitelisted

---

#### 3 Exceptional Paths

- **Default / Liquidation**  
  Oracle calls `MBSPool.registerLoss(lossAmount)` → pool writes down Equity first, then BBB, etc.

- **Pool Security**  
  Only pools registered via `MBSHook.allowPool()` can call hook callbacks; others revert.

---

#### 4 External Calls Needed

| Who | Calls | Why |
|-----|-------|-----|
| Borrower | `makePayment()` | Monthly payments |
| Lender | `fundMortgage()`, `securitiseMortgage()` | Origination & securitisation |
| Anyone | `swapExact…()` on V4 pool | Buy / sell tranches |
| Oracle | `updateRates()`, `registerLoss()` | Push data |
