//! Upstream's seed-799 cross-slab regression, recorded op by op.
//!
//! [`hexane_regression_command`] runs **one** of upstream's regressions — the
//! replay of seed 799 out of `cross_slab_fuzz`
//! (`hexane/src/tests.rs:2711-2743`) — and prints what the reference's own
//! `Column<u64>` did with it, one JSON record, one line.
//!
//! # Why this is recorded rather than re-derived
//!
//! The port's `cross_slab_fuzz` covers the *shape* of that case over a thousand
//! seeds (`tests.rs:2745-2784`), but it cannot reproduce upstream's seed 799,
//! and the reason is worth stating exactly rather than as "different
//! generators", because the two are closer than that. On a 64-bit target both
//! are **Xoshiro256++**: `SmallRng` is `Xoshiro256PlusPlus` (`rngs/small.rs:15`)
//! and `std.Random.DefaultPrng` is `Xoshiro256` (`Random.zig:13`). What differs
//! is everything *upstream* of the algorithm — the **seed expansion**, PCG32 in
//! `rand_core` (`seedable_rng.rs:109-121`) against SplitMix64 in Zig
//! (`Random/Xoshiro256.zig:57-65`), and the bounded reduction each side applies
//! to one draw. So the streams diverge at the first draw and no seed in one
//! names an op list in the other.
//!
//! Which leaves "seed 799" in the port a *name*: it named the number upstream's
//! failure report carried and nothing else. A regression vector that is only a
//! name proves nothing about the op list upstream actually ran, so the op list
//! is taken from the only source that has it — the generator upstream used,
//! drawing the same requests in the same order.
//!
//! Nothing about the op list is guessed here. `values`, `budget` and every
//! step's `index`/`delete`/`insert` are the reference's own draws, produced by
//! the calls below, each carrying the upstream line it comes from.
//!
//! # The draws are the contract
//!
//! Each `random_range` below reproduces one upstream draw *exactly*, and three
//! things about it are part of the contract rather than style:
//!
//! * **The types.** `random_range(0u32..20)` and `random_range(0usize..20)` are
//!   two different requests against the same stream — they sample different
//!   widths and consume different amounts of it — so the `u32`/`u64`/`usize`
//!   in each range is upstream's, not a convenience.
//! * **The order.** The row count is drawn first, then one value a row, then
//!   the budget, then each operation's four draws in their own order.
//! * **The ranges.** `0u32..20`, `0u64..5`, `0u32..6`, `0..len`,
//!   `0..max_del + 1` and `0u32..4`, each half-open exactly as upstream wrote
//!   it, so `3..=8` budgets and `0..=4` values fall where they fell.
//!
//! # Why `rand` is a direct, version-pinned dependency
//!
//! `SmallRng` is the generator `tests.rs:2714` seeds, and a vector built on
//! "whatever `rand` resolves to" is not reproducible: the op list, and so this
//! record and the whole golden vector derived from it, would move with a
//! dependency bump. The manifest therefore names `rand = "=0.10.3"`, the
//! version this lock already resolves for `automerge` and `hexane` — so the
//! dependency costs no new package and no recompiled crate. (0.10.3 gates no
//! `SmallRng` behind a feature: `rngs/mod.rs:106` exports it unconditionally, so
//! there is no `small_rng` feature to ask for, and the default features are
//! what upstream's own test binary was built with.)
//!
//! # A record
//!
//! | field      | what it is |
//! |------------|------------|
//! | `kind`     | `hexane-regression` |
//! | `seed`     | `SEED`, the seed upstream replays                                   |
//! | `values`   | the initial rows, the `n` values drawn at `:2717` |
//! | `budget`   | `max_segments`: the slab budget in **runs**, `3..=8` (`:2718`) |
//! | `steps`    | one entry per splice that ran, in order |
//!
//! and each step:
//!
//! | field      | what it is |
//! |------------|------------|
//! | `index`    | where the splice landed, `idx` from `:2727` — the *position*, not the step number |
//! | `delete`   | how many rows it removed, `del` from `:2729`, counted from `index` |
//! | `insert`   | the values spliced in, `new_vals` from `:2731`, zero to three of them |
//! | `expected` | the reference column's rows **after** this step, `col.to_vec()` |
//! | `hex`      | `col.save()`, the reference's canonical encoding of that same state |
//!
//! `index` is the position and the array order is the step: a consumer replays
//! step *k* by splicing at `index`, deleting `delete` rows and inserting
//! `insert`, then checks its own rows against `expected` and its own canonical
//! bytes against `hex`. Both are the reference's own answer, so neither is a
//! restatement of the operation.
//!
//! **The step count is whatever ran.** Upstream's loop breaks when the column
//! is empty (`:2724-2726`), and a record that padded back to ten steps would
//! be recording something that did not happen, so a short `steps` is the
//! answer, not a truncated one.
//!
//! `hex` is `Column::save()`, which is the *canonical* encoding — the same
//! function `validate_encoding` checks (`:1347-1352`), so it is the bytes both
//! implementations must agree on, and not a serialisation either side chose.
//!
//! # The check that is not optional
//!
//! Upstream asserts the column against a plain model after every operation
//! (`:2740`). That assertion runs here too, before a step is recorded: a record
//! whose `expected` disagreed with the model would be a vector asserting that
//! the reference is wrong, generated by the same run that could have said so.
//! A mismatch fails the command rather than emitting the record.

use std::error::Error;
use std::io::Write;

use hexane::Column;
use rand::{RngExt, SeedableRng};
use serde_json::{Value as Json, json};

use crate::{emit, hex_encode};

/// The seed upstream replays out of its own sweep (`tests.rs:2711-2714`), and
/// the number its failure report carries.
const SEED: u64 = 799;

/// How many splices upstream's loop offers (`tests.rs:2722`). Not how many run:
/// the loop breaks early on an empty column, and the record keeps the count
/// that actually happened.
const OPS: usize = 10;

/// The most rows one splice may delete (`tests.rs:2728`), which caps `del`.
const MAX_DELETE: usize = 5;

/// The most values one splice may insert (`tests.rs:2730`), which caps
/// `ins_count`.
const MAX_INSERT: u32 = 4;

/// `hexane-regression`: draw upstream's seed-799 op list from upstream's own
/// generator, run it through the reference's `Column<u64>`, and print what the
/// reference made of every step.
pub fn hexane_regression_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    // `:2714`. `SmallRng` is `Xoshiro256PlusPlus` on a 64-bit target
    // (`rngs/small.rs:15-18`), and it is seeded by the u64 itself — no entropy,
    // no thread state, no wall clock, so this run is a function of `SEED`.
    let mut r = rand::rngs::SmallRng::seed_from_u64(SEED);

    // `:2716`. The row count: a `u32` draw in `0..20`, plus five.
    let n = r.random_range(0u32..20) as usize + 5;
    // `:2717`. One `u64` draw in `0..5` a row.
    let values: Vec<u64> = (0..n).map(|_| r.random_range(0u64..5)).collect();
    // `:2718`. The slab budget: a `u32` draw in `0..6`, plus three.
    let budget = r.random_range(0u32..6) as usize + 3;

    // `:2719-2720`. The reference column, built through the reference's own
    // constructor at the budget just drawn, against a plain `Vec` model.
    //
    // The budget counts **runs**, not bytes: three to eight run segments
    // against values drawn from `0..=4` is what cuts a slab in the middle of a
    // run sequence, so the runs either side of a cut carry the same value and
    // every splice has to merge across that seam. That is the whole mechanism
    // this case exists for, and it is why `hex` is recorded per step rather
    // than once at the end.
    let mut col = Column::<u64>::from_values_with_max_segments(values.clone(), budget);
    let mut mirror = values.clone();

    let mut steps: Vec<Json> = Vec::new();
    for op in 0..OPS {
        // `:2723-2726`. The column's length decides whether another operation
        // runs at all; a `break` here ends the record where the run ended.
        let len = col.len();
        if len == 0 {
            break;
        }

        // `:2727-2731`. Four draws, in this order, with these types.
        // `idx` and `del` are `usize` because `len` is; `ins_count` is a `u32`
        // draw widened to `usize`; each inserted value is a `u64` draw.
        let idx = r.random_range(0..len);
        let max_del = (len - idx).min(MAX_DELETE);
        let del = r.random_range(0..max_del + 1);
        let ins_count = r.random_range(0u32..MAX_INSERT) as usize;
        let inserted: Vec<u64> = (0..ins_count).map(|_| r.random_range(0u64..5)).collect();

        // `:2738-2739`. The reference's splice, and the model's. The model is
        // handed the same iterator rather than the `Vec` so `inserted` is still
        // owned afterwards, for the record.
        col.splice(idx, del, inserted.iter().copied());
        mirror.splice(idx..idx + del, inserted.iter().copied());

        // `:2740`. Upstream's own assertion — `assert_eq!(col.to_vec(), mirror)`
        // — after **every** operation rather than at the end of the round. It
        // is what makes `expected` evidence: without it the record would be
        // the reference's answer to an op list nobody checked was well formed.
        let actual: Vec<u64> = col.to_vec();
        if actual != mirror {
            let mismatch = format!(
                "seed {SEED} step {op}: splice({idx}, {del}, {inserted:?}) left the column \
                 holding {actual:?}, and the model holding {mirror:?}"
            );
            return Err(mismatch.into());
        }

        // The state *after* this step, from the reference: its rows, and the
        // canonical bytes for them.
        steps.push(json!({
            "index": idx,
            "delete": del,
            "insert": inserted,
            "expected": actual,
            "hex": hex_encode(&col.save()),
        }));
    }

    let record = json!({
        "kind": "hexane-regression",
        "seed": SEED,
        "values": values,
        "budget": budget,
        "steps": steps,
    });
    emit(out, &record)?;
    Ok(())
}
