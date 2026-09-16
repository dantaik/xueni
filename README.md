# Xueni · 雪泥

A multi-author writing system that lives entirely on Ethereum (**Xueni** is the pinyin of 雪泥,
snowy mud, from the idiom 雪泥鸿爪 — the prints a wild goose leaves in the snow). **One non-upgradeable,
ownerless smart contract**, in which every wallet is its own author (`msg.sender`). Text,
titles, tags and images all live in L1 calldata, with no off-chain dependencies.

The interface reads in **English by default and can be switched to Chinese** at any time.

Technical design: [`xueni-spec.md`](./xueni-spec.md)

## Download for macOS

[**Xueni for macOS**](https://github.com/dantaik/xueni/releases/latest/download/Xueni-macOS.dmg) —
one universal application for Apple Silicon and Intel, macOS 13 or later, around ten megabytes. It is
this repository's web app in a window, not a second program: the same reader, the same permanent
caches, the same two chains, and links to explorers open in your own browser. Publishing from it signs
through WalletConnect — an application has no browser extension in it — so the write tab shows a QR
code to scan with a wallet on your phone.

Today's builds are ad-hoc signed rather than signed with an Apple Developer ID, so macOS refuses the
first launch with "the developer cannot be verified": right-click the app, choose Open, and Open again
in the dialog. macOS remembers the answer. To build it yourself, or to read exactly what the shell
does, see [`desktop/README.md`](./desktop/README.md).

## For iPhone

[`ios/`](./ios/README.md) holds a native reader for iPhone: SwiftUI over two local SwiftData
databases — the chain cache (posts, documents, images, scanned ranges) and the reader's own
(followed authors, the draft) — with the reading logic ported to Swift as a package,
`XueniKit`, that is held to the codec's own test vectors and runs its tests on Linux. It reads
both chains from your choice of nodes, keeps everything it has read on the phone, resolves ENS
names, follows authors by the cheap path, searches what it holds, and exchanges archive and
settings files with the web app and the CLI. It is drawn in black, white and grey. The phone
does not publish: a draft written there leaves as a `.md` that "Import .md…" and `xueni publish`
both read. Open `ios/Xueni.xcodeproj` in Xcode 16 to build it; `.github/workflows/ios.yml`
builds it on every change.

## Quick start

The contract is deployed, and both its address (the same on every chain, via CREATE2) and each
chain's default RPC endpoints are built into the front end — clone and run, **no configuration
needed**:

```bash
cd webapp && npm install && npm run dev
```

Deploying to a static host such as Vercel or Netlify is equally configuration-free: `vercel.json`
is ready, so import the repository as it is. `npm run build` puts the output in `dist/`.

**Optional — deploy your own copy of the contract** (anyone may; the deployer holds no privilege):

```bash
cd contracts && forge install foundry-rs/forge-std
forge script script/Create2DeployXueni.s.sol:Create2DeployXueni \
  --rpc-url $ETH_RPC --broadcast   # the contract and the fan-out hook beside it
                                   # (PRIVATE_KEY comes from the environment; the script reads it with vm.envUint)

# Point the front end at your own copy. Vite inlines these at build time, so a
# change here means rebuilding.
cat > webapp/.env.local <<EOF
VITE_XUENI_ADDRESS=0xYourXueniAddress
VITE_MULTI_HOOK_ADDRESS=0xYourFanOutAddress
VITE_RPC_URL=https://eth.drpc.org
VITE_CHAIN_ID=1
EOF
```

**Reading**: visit `/` (the newest posts from both Ethereum and Taiko, merged newest-first by block
time), `/ethereum` or `/taiko` (one chain only), `/author/0xAUTHOR` (that author's posts from both
chains merged; `/taiko/author/0x…` for one chain), `/taiko/tx/0xTXHASH/0` (a single post — the path
names the chain, and the trailing number is the event's index within the transaction; an older link
without a chain is looked up on both chains and then redirected), or `/scan` (the multi-segment block
ranges this browser has scanned so far, reachable from the footer). Add `?headless=1` to a post URL
(`/taiko/tx/0xTXHASH/0?headless=1`) to get that post with no app around it — no masthead, no site
footer, no back button and no previous/next cards, just the letter, its byline and its provenance —
for embedding one in an iframe or a preview pane. It applies to post URLs only and to that page
alone: a link followed out of it lands in the ordinary interface. "Copy embed code" in the share menu
writes that snippet for you.
**Writing**: the "Wallet and network" panel at the top of the Write tab — connect a wallet, choose which
chain to publish to (it follows the wallet's own network until you pick one, and then it is remembered),
and switch the wallet's network in one click when it is on the wrong chain → then a title (32 bytes at
most) + tags + a Markdown body (CodeMirror editing, full-width preview) → publish. To reference another
post from the body, write `[text](0xTXHASH/0)` (spec §8.1).
**Hooks**: a post can go through a **hook** — a contract of anyone's, named per post, that the journal
calls once after the post is recorded, with the call's ETH and whatever data you attach: a publication
with members, a fee, an index by topic, a collectible (spec §4.1). "None" is a plain post and costs the
least; "One hook" takes an address, hex data and an amount of ETH; "Several hooks" packs a list of them
into the fan-out hook deployed beside the contract. The estimate shows the ETH going to the hook. A post
page shows the hook it went through (named where this build knows the address) and its data in "Raw";
the reader never runs anything for a hook.
**Relaying (`publishFor`)**: "Sign for a relayer instead" signs the post with the wallet (EIP-712, no
transaction, no gas) and produces a **ticket** — one small JSON file naming the chain, the contract, the
post, the hook, the deadline you chose (1, 7 or 30 days) and the signature. Anyone can paste or open
that file in the "Relay a signed post" panel at the foot of their own Write tab and send it — the panel
checks the file's shape, its chain and contract, its deadline and, for a signature that is not the 64
or 65 bytes a wallet key makes, that the author is a contract account, before anything goes out; it lands
under your address, as your next post, and the post page says who sent it on your behalf. A ticket is
for one specific post number, so publishing anything yourself in the meantime cancels it.
**Tags and search**: a tag on a row or under a post opens `/tag/<name>`, and the magnifier in the
masthead (⋯ menu on a phone) opens `/search`, which finds a word in any title, tag or body — matched as
a substring, so Chinese works without word splitting. Both cover the posts this browser has read, say
so in their subtitle, and offer the ordinary "read earlier posts" as the way to cover more. Neither
asks anything of a server: no node can filter on the inside of compressed calldata, and an index that
went looking would be a crawler.
**Reading a post**: `←` and `→` move to the author's previous and next post on the same chain, unless
you are typing. Clicking an image opens it full size with its alt text as the caption, so a picture that
cost gas by the byte can actually be looked at. Printing takes the app away and leaves the letter, black
on white, with the chain and the full transaction hash under it, because on paper a link is not a link.
The "Share" menu in the provenance line copies the canonical link, an `<iframe>` snippet for the headless
view, or the Markdown reference `[title](0xTXHASH)` that quotes this post from inside another one.
**Names**: an author who has an ENS name is shown by it — in bylines, on their own page, and at
`/author/xiaoman.eth`, which resolves the name and shows their posts. Their ENS avatar replaces the
identicon once it has loaded, and their `description`, `url`, `com.twitter` and `com.github` records
become a short profile above the list. The contract knows only addresses and always will; ENS is the
identity layer already on chain, under a registry with no owner, so none of this needs a server. A
reverse record is a claim the address makes about itself, so the name is resolved forward again and
only shown when it comes back to the same address. Every lookup is best effort and only Ethereum
answers it.
**Following**: "Follow" on an author's page (or under any post of theirs) keeps them in a list held in this
browser and nowhere else, and `/following` — one click from the home feed — shows their newest posts merged
across both chains. It is the cheap path the contract was designed for: the home feed has to sweep block
ranges because there is no global head pointer, but every author has one of their own, and each of their
posts names the block of the previous one. So this feed costs one head read per author per chain and then a
walk down single blocks, with no range scan anywhere. A divider marks where you got to last time. The list
costs no gas, tells the author nothing, can be pruned on `/settings`, and travels in the settings file.
**Relations**: a post can say what it is to other posts, in its own front-matter and therefore on chain:
a reply (`re`), a replacement for an earlier version (`supersedes` — the only honest kind of edit on an
immutable chain), a continuation (`prev`), a place in a `series`, and the `lang` it is written in. Fill
them in the folded "Relations" section of the Write tab, or choose "Reply" in a post's share menu to
start one with the reference already there. Reading, the forward half comes from the post itself and is always
there; the backward half — its replies, what continues it, whether a newer version exists — is drawn
from the posts this browser has read, and says so.
**The letter as the chain holds it**: every post page has "Raw", which shows the exact decompressed
document — front-matter included — with what it cost to store and what it decompresses to, and
"Download .md", which saves those same bytes as a file named for the day and the title. "Import .md…"
in the Write tab brings such a file back as a draft: front-matter this version knows fills the fields,
and anything it does not know is named rather than silently carried on chain.
**Images**: paste or drop one straight into the body and it is attached and referenced where the cursor
is; the preview shows both an attached file and an image already on chain (`eth:0x…`). An image whose
processed bytes this browser has already published on this chain is referenced again rather than paid
for again — the estimate says "already on chain · no cost" before you sign, and no transaction is sent.
**Wallets**: every wallet that announces itself (EIP-6963) is listed by name and icon in the "Wallet and
network" panel, so a browser with two of them is a choice rather than a coin toss; the choice is
remembered. Build with `VITE_WALLETCONNECT_PROJECT_ID=<id from Reown Cloud>` to add WalletConnect as
one more entry — the only way to sign on a device with no extension. Without that variable the entry
does not exist and none of its code is in the bundle.
**Drafts**: what you are writing — title, tags, body and attached images — is saved in this browser
half a second after you stop typing, and offered back the next time the Write tab opens, so a reload
or a wallet sending you away and back loses nothing. "Discard" throws it away; publishing clears it.
**Paging**: "Load earlier posts" at the foot of the feed and author pages scans backwards a segment at a
time — a block range already scanned is answered from the local cache and never requested again. When the
feed has unscanned blocks between two scanned segments, it says so in the middle of the list and offers to
fill just that gap.
**Networks**: the contract sits at the same address on Ethereum mainnet and Taiko mainnet, and the front
end treats the two as one journal: the feed and author pages read both at once, and each post is labelled
with its network (click it for a single-chain view; the list header has "View all" to come back). Each
chain scans independently, and where the slower one has only reached is marked in the list ("The posts
below may be incomplete: Taiko has only been scanned back to …"); "Keep scanning" / "Load earlier posts"
deepens whichever chain is furthest behind. Scan ranges, titles, bodies and image caches are separate per
chain, and the footer gives each chain a line.
**Scanning**: the feed scans block ranges newest-first, and every finished segment (one `eth_getLogs`)
shows its posts immediately rather than waiting for the whole scan; leaving the feed (to open a post, an
author or the settings) does not interrupt it. Each scan (opening the feed, one click of "Load earlier
posts") reads at most `scanBlocks` blocks from the node (270,000 by default, see
`webapp/src/lib/chains.js`), with already-scanned ranges not counting towards it; nothing below the
contract's deployment block (`deployBlock`) is ever read. That ceiling is spelled out in the on-page scan
progress, on `/scan`, and in the console.
**RPC endpoints**: the ⚙ in the top right opens `/settings` (folded into the ⋯ menu on a phone), where each
chain can hold several endpoints in order — the first is used, and a failure falls back to the next (a
failed endpoint is set aside briefly rather than retried on every request). Saving takes effect at once,
without a reload.
**Rescan delay and caching**: the same `/settings` page sets the "blockchain rescan delay" — within that
long after a scan finishes, reopening the feed or an author page shows what the last scan found instead of
asking the node for new blocks (1 minute by default; 0 scans every time). It only decides when new blocks
are read, and never misses a post. What has already been read is cached **permanently**: on-chain data
does not change, so one post's metadata, title, body and images are never requested twice.
**Language**: the interface is in English by default and switches to Chinese from the header (the EN/中
button, or the ⋯ menu on a phone) or from `/settings`. The choice applies immediately, is kept in this
browser, and travels in the settings file. It changes the interface only — a post stays on-chain in the
language it was written in.
**Archive**: "Export everything read here" on `/settings` writes one `.xueni.json` file holding the exact
stored text of every post this browser has read and the images they refer to; an author page has "Export
this author", which first walks their list back to their first post so the bundle can say it is complete.
Import one into another browser and those posts open with no node at all: the local cache is the only
copy a reader controls, and until it is a file it is a browser profile that a cleared cache takes away.
It is also the answer to history expiry (EIP-4444) — a reader years from now, whose endpoints no longer
serve calldata from today, opens a bundle instead of running an archive node. `xueni export` writes the
same format from a terminal. An import claims only what it can prove: the posts it carries and the
authors it says are complete, never the home feed, which is a claim about every author at once.
**Backup and restore**: "Export settings" on `/settings` writes the endpoint lists, rescan delay, publish
target, language, theme, followed authors and log switch to one JSON file; "Import settings" lists what it would
change first and applies it on confirmation, with no reload.
**Interface**: an author is shown as a blockies icon generated from their address plus the last 6
characters of it (contracts and transaction hashes still use `0x1234…abcd`). On a narrow screen the
language, theme and settings controls fold into the ⋯ menu and everything else stays on one row.
**Console**: every node request and every local cache hit writes one console line, labelled with the chain;
`?log=0` turns it off.
**Cost estimate**: gas (from the node) plus ETH/USD (from CoinGecko) shown live before publishing —
with the two things that actually move the price. WHEN: the last day of base fees, sampled one block
header an hour from the chain itself, drawn as a small line with the cheapest hour named and what this
post would have cost then. WHERE: the same draft priced on the other network, with one click to send
it there instead. Both degrade quietly — no USD when CoinGecko is unreachable, no line when a node
will not serve headers.

## Command line

`xueni` publishes, reads, exports and verifies posts from a terminal — for scripting, for bulk work,
and for a nightly backup of an author. It shares the payload layer with the web app rather than
reimplementing it, so a post published from the command line is byte for byte the post the browser
would have written.

```bash
cd cli && npm install
node bin/xueni.js fetch taiko 0xTXHASH          # print the post
node bin/xueni.js author all 0xAUTHOR           # their titles, newest first
node bin/xueni.js export 0xAUTHOR --out ./mine  # every post as .md, plus an importable archive
node bin/xueni.js publish letter.md --chain taiko --dry-run
```

`PRIVATE_KEY` comes from the environment and is never an argument. See [`cli/README.md`](cli/README.md)
for every command and option.

## The post codec

The conversion between a post as a person sees it — title, tags, body, front-matter — and the
calldata of the `publish()` call that stores it is specified, normatively and with a format version,
in [`codec/SPEC.md`](codec/SPEC.md), and implemented as pure functions in [`codec/`](codec/README.md)
(`xueni-codec`): no wallet, no node, no I/O — a post in, `0x…` out, and back. Version 1 is the format
every post so far uses; a later version is marked by a leading byte no brotli stream can begin with, so
an older reader fails loudly on a newer post rather than showing garbage.

```js
import { postToCallData, callDataToPost } from 'xueni-codec/node';   // ../codec/src/node.js from inside this repo
const callData = postToCallData({ title, tags, markdown, meta });   // what a wallet signs
const post = callDataToPost(tx.input);                              // { title, tags, markdown, meta, text, compressedBytes, call }
```

Revision 1.2 of the spec covers the contract's two other calls — a post through a hook
(`publish(bytes32,bytes,address,bytes)`) and a post relayed on the author's behalf (`publishFor`) —
which the codec tells apart by selector and reports in `call` (the hook, its data, and for a relayed
post the author, deadline and signature); `postToCallData(post, { hook, hookData })` and
`encodeRelayedPost` write them. The title and the payload inside all three are the same bytes.

The web app and the CLI still encode through `webapp/src/lib/payloadText.js` and `title.js`; the
codec's test suite holds itself to those modules byte for byte, on fuzzed input, so the three cannot
drift apart unnoticed. The spec's §10 is the security model — every field of a post is a stranger's
bytes — and the library enforces the parts that are its own: decompression is bounded while it
happens (a 106-byte payload can otherwise unpack to 64 MiB), and control characters are refused.

## Testing

```bash
cd webapp
npm test            # vitest: the data layer (scanning, caching, merged feeds, routing, config) and components
npm run build       # build the site into dist/
npm run test:e2e    # Playwright (Chromium): the built output + a local JSON-RPC mock node (both chains)
npm run check       # all three

cd contracts && forge install foundry-rs/forge-std && forge test   # the contract and its hooks (Foundry)
```

The contract tests (`contracts/test/`) cover `Xueni` — the plain call, hooks that gate, charge,
record, reject and re-enter, ETH forwarding, `publishFor` with EOA (65- and 64-byte), ERC-1271 and
malleated signatures, deadlines and the index-as-nonce — and the three shipped hooks.

The e2e mock node (`webapp/test/e2e/rpcServer.mjs`) serves the demo world (`src/lib/fixtureWorld.js`) over
JSON-RPC at the real contract's deployment heights: `eth_getLogs` returns ABI-encoded Post events whose
bodies are brotli-compressed `publish()` calldata, so viem, chainIO and the brotli WASM all really run.
During development, `npm run dev` and then `/?fixtures=1` shows the same demo data from memory. GitHub
Actions (`.github/workflows/ci.yml`) runs all three steps on every PR, and the `cli` job runs the
command-line tool's tests against that same mock node (`cd cli && npm test`). The `codec` job runs the
post codec's conformance suite (`cd codec && npm test`), which includes its test vectors and the
byte-for-byte checks against the web app's payload modules. The `contracts` job runs `forge test`. The macOS application has
its own workflow (`.github/workflows/desktop.yml`), which builds on a `v*` tag and on a pull request
that touches `desktop/`; its image-encoding crate is tested with `cd desktop/src-tauri/transcode &&
cargo test`.

Two of the end-to-end specs are worth knowing about. `following.spec.js` inspects the mock node's call
log and asserts that reading a followed author never issued an `eth_getLogs` spanning more than one
block, which is the claim the contract's head pointer exists to make. `archive.spec.js` exports a bundle
in one browser, imports it into a second, opens that author's page and one of their posts there, and
asserts that not one transaction was read.

Most of the demo world is written in English. Two of its posts are deliberately left in Chinese: they are
the multi-byte-title fixtures — one title is exactly 27 bytes of UTF-8, the other is a `bytes32` title cut
mid-character and ending in U+FFFD — and neither case can be reproduced with ASCII. They double as
something real to look at in the bilingual reader.

## Deterministic deployment (CREATE2 · the same address everywhere)

Xueni is deployed with CREATE2 through the canonical deterministic deployment proxy (Arachnid,
`0x4e59b44847b379578588920cA78FbF26c0B4956C`). A CREATE2 address is decided only by
`(deployer, salt, init-code hash)`, and the proxy itself can be deployed to the same address on any EVM
chain with one replayable transaction (a one-time account) — so **Xueni has the same address on every EVM
chain**:

```
Xueni address:     0x0000003CE1a46C7Fbb02B9E1a0A4709AD9cb15d9   (6 leading zeros)
salt:              0x8aa497dea52803954d13c50daba9a4406e3a311f2798d03479c5aa8739f7f135
deployer (proxy):  0x4e59b44847b379578588920cA78FbF26c0B4956C
init code hash:    0x3c02f70eedda0c718075c36cfb80973b0a56089a9e48028a0edb43193f5b25ca

MultiHook address: 0x0000098B1F5b2Fb1F7251Af47F8df15eb319ed10  (5 leading zeros; constructed with the Xueni address)
salt:              0xfffbb2a59c4aca17a58d9dd950e154fd23791d671715de15991faa19a76bd6de
init code hash:    0x035f84f8912b4ca547346eaa4b24e7ad295a840277f743cdd16506ba8dd048a6
```

The fan-out hook (`src/hooks/MultiHook.sol`) is deployed the same way and lands at an address of its
own that is likewise the same on every chain. Both are built into the front end
(`DEFAULT_XUENI_ADDRESS`, `DEFAULT_MULTI_HOOK_ADDRESS`), which reads them on every chain — a chain
without them reads as empty. `forge inspect src/Xueni.sol:Xueni bytecode` gives the init code to mine
a new salt with if the source changes.

An earlier contract at `0x000000AE2f2249c497cfc5F262dd1491634C361C` holds the posts published before
Xueni. It is immutable and stays on chain, but nothing here reads it any more: the app, the
command-line tool and the macOS app read Xueni alone.

- **The deploy script**: `script/Create2DeployXueni.s.sol`, idempotent (if an address already holds
  code it verifies and exits). Anyone may run it, and the deployer holds no privilege.
- **Chains where the proxy is missing**: first send ≥ 0.01 ETH (100,000 gas × 100 gwei) to the one-time
  signing account `0x3fab184622dc19b6109349b94811493bf2a45362`, then replay the raw signed transaction from
  `output/deployment.json` in Arachnid's repository (replaying it on any chain produces the same proxy
  address):

  ```bash
  cast publish 0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222
  ```

- **Bytecode drift**: any change to `Xueni.sol` changes the init code hash, and therefore the address. Mine a
  new salt and update the constants in `Create2DeployXueni.s.sol`:

  ```bash
  cast create2 --starts-with 000000 --init-code $(forge inspect src/Xueni.sol:Xueni bytecode)
  ```

- **Verifying the contracts**: the explorer API is Etherscan's V2, one key for every chain — pass
  `--chain <chainid>` and let forge build the URL rather than naming a V1 endpoint, which is retired:

  ```bash
  XUENI=0x0000003CE1a46C7Fbb02B9E1a0A4709AD9cb15d9
  HOOK=0x0000098B1F5b2Fb1F7251Af47F8df15eb319ed10
  forge verify-contract $XUENI src/Xueni.sol:Xueni --chain 1 --etherscan-api-key $ETHERSCAN_API_KEY --watch
  forge verify-contract $HOOK src/hooks/MultiHook.sol:MultiHook --chain 1 \
    --constructor-args $(cast abi-encode 'constructor(address)' $XUENI) \
    --etherscan-api-key $ETHERSCAN_API_KEY --watch
  ```

  Taiko is the same with `--chain 167000`; its source lands on Taikoscan, which shares the API.

## Deployment record

**Xueni** — the contract every surface reads — at `0x0000003CE1a46C7Fbb02B9E1a0A4709AD9cb15d9` on both chains:

| Chain | Chain ID | Deployment block | Deployment tx | Deployer | Date |
|---|---|---|---|---|---|
| Ethereum mainnet | 1 | 25,980,697 | [0xe375…d4b8](https://etherscan.io/tx/0xe375aef357501b9659c61f8a4378e7b152f38a28fd043132aa2b9e6e59c3d4b8) | `0x327f…c458` | 2026-09-15 |
| Taiko mainnet | 167000 | 11,413,668 | [0xea2f…a81f](https://taikoscan.io/tx/0xea2f2f654c3cc115a3b1be9182d02071b3b46df319f2fbf16fdde75b0ca8a81f) | `0x327f…c458` | 2026-09-15 |

**MultiHook** — the fan-out hook beside it — at `0x0000098B1F5b2Fb1F7251Af47F8df15eb319ed10`:

| Chain | Chain ID | Deployment block | Deployment tx | Deployer | Date |
|---|---|---|---|---|---|
| Ethereum mainnet | 1 | 25,980,700 | [0xdeda…6248](https://etherscan.io/tx/0xdedae15fa3c2bd42fe3e4d20d709ae6be0030748d02983d58eab1de70b096248) | `0x327f…c458` | 2026-09-15 |
| Taiko mainnet | 167000 | 11,413,668 | [0x622e…31f6](https://taikoscan.io/tx/0x622e8a8ff130ff9987934426ba114eebce197eca6d5e61ae162ec011d14131f6) | `0x327f…c458` | 2026-09-15 |

The address is itself the proof of what is deployed: CREATE2 fixes it from the salt and the init
code hash alone, both pinned in `script/Create2DeployXueni.s.sol`, and each transaction above
carries the matching salt. The deployer holds no privilege over either contract; neither has an
owner and neither can be upgraded. Each chain's Xueni deployment block is its `deployBlock` in
`webapp/src/lib/chains.js`: no block below it can hold a Post event, so no sweep ever reads that far.

The earlier contract at `0x000000AE2f2249c497cfc5F262dd1491634C361C`, deployed 2026-09-02 on both
chains and verified, is no longer read by anything here. Posts published to it stay where they are,
on chain and readable through an explorer, but they do not appear in this app.

## License

MIT
