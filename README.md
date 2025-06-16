
# 📓  The Hacker’s Diary
*A weekly whodunit where every clue compiles, every chapter forks main-net, and every reader walks away smarter.*

### What is this?

**The Hacker’s Diary** is an open, code-driven chronicle of notable Web3 intrusions.  
For each incident we publish two artefacts, side by side:

1. **The Story** – a prose-heavy “diary entry” that traces the attacker’s thinking, uncensored addresses included.  
2. **The Proof** – a self-contained Foundry test that replays the breach on a fork, shows the money move, and asserts the profit.

If you can’t `forge test` it, we don’t ship it.


### Directory anatomy

```

thehackersdiary/
└─ 2023/
    └─ Ethereum/
        └─ Euler-13-06/
            ├─ Euler-13-06.t.sol      # Foundry PoC (compiles to green)
            └─ Diary.md               # first-person narrative
```

### How to run an episode

1. Install Foundry → `curl -L https://foundry.paradigm.xyz | bash`  
2. Point it at an archive node → `export FOUNDRY_ETH_RPC_URL=<RPC>`  
3. `cd 2023/ethereum/Euler-13-06`  
4. `forge test -vvvv`

You’ll watch the flash-loan, the vulnerable call, the liquidation, and the final profit all occur exactly as on main-net.

### Vision

Hack write-ups often feel like autopsies conducted with rubber gloves and passive voice.  
The Hacker’s Diary aims for the opposite:

* **Human first-person narration** – the notes an attacker might leave themselves.  
* **Full transparency** – no ellipses in addresses or hashes.  
* **Executable truth** – every claim is backed by code that succeeds or fails in CI.

We want defenders, auditors, and curious developers to **feel** the exploit, not just read about it.

### Contributing

*Fork → add a new dated folder → drop in your green Foundry test and a `diary.md` written in the same storytelling style → open a PR.*

Checklist:

* Use unbroken addresses / tx hashes.  
* Close the flash-loan (or equivalent) so profit is real.  
* Cite previous researchers in `references.md`.  
* Keep exploits already patched and disclosed—no zero-days, please.


### Licence & ethics

*Code*: MIT  
*Text*: CC-BY-4.0

The contracts here are intentionally vulnerable. Never deploy them. Use this repository for education, incident-response drills, and improving defensive tooling—nothing else.

> “Those who understand how yesterday was hacked design safer tomorrows.”  
> — *The Hacker’s Diary*
