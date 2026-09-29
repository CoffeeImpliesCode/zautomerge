# Conformance Assets, Test Topology, History, and Non-Rust Surface

## Scope

Read-only reference checkout: `~/projects/github-automerge-automerge` at commit `ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`.

Paths covered, with line counts where counted:

| Path | Lines / size | Notes |
|---|---|---|
| `rust/automerge/tests/test.rs` | 4450 | 140 `#[test]` + 4 helpers |
| `rust/automerge/tests/text.rs` | 1154 | 20 `#[test]` + 1 `proptest!` + 9 helpers |
| `rust/automerge/tests/diff_marks.rs` | 1508 | 36 `#[test]` + 1 helper |
| `rust/automerge/tests/batch_insert.rs` | 1065 | 46 `#[test]` + 2 helpers |
| `rust/automerge/tests/block_tests.rs` | 946 | 19 `#[test]` + 2 helpers |
| `rust/automerge/tests/text_encoding.rs` | 639 | 15 `#[test]` (each × 4 encodings) |
| `rust/automerge/tests/rich_text_fuzz_crash.rs` | 243 | 9 `#[test]` + 2 helpers |
| `rust/automerge/tests/convert_string_to_text.rs` | 72 | 3 `#[test]` |
| `rust/automerge/tests/test_save_load_orphans.rs` | 84 | 3 `#[test]` + 1 helper |
| `rust/automerge/tests/test_mark_patches.rs` | 41 | 1 `#[test]` |
| `rust/automerge/tests/fixtures/` | 9 files, 1162 B total | wire-format regression corpus |
| `rust/automerge/tests/fuzz-crashers/` | 8 files, 893 B total | `cargo fuzz` artifact directory |
| `rust/automerge/fuzz/` | `Cargo.toml` 417 B, `fuzz_targets/load.rs` 960 B, `.gitignore` 23 B | cargo-fuzz crate, outside the workspace |
| `rust/automerge/src/` | 163 files, ~65k lines | 34 files declare `#[cfg(test)] mod tests` |
| `rust/CHANGELOG.md` | 424 lines | workspace-level changelog; the compatibility contract |
| `rust/hexane/CHANGELOG.md` | 2.7 KB | 3 entries only |
| `rust/Cargo.toml` | workspace root, 8 members | |
| `rust/rust-toolchain.toml` | 29 B | `channel = "1.90"` |
| `rust/deny.toml` | 9.2 KB | cargo-deny policy |
| `rust/hexane/tests/pending.rs` | 145 lines | 6 `#[ignore]`d known-bug tests |
| `rust/hexane/src/tests.rs` | 193.2 KB | single huge unit-test module |
| `rust/hexane/benches/` | 9 files | divan |
| `rust/hexane/proptest-regressions/tests.txt` | 2.0 KB | persisted failing proptest seeds |
| `rust/automerge-cli/tests/integration.rs` | 2 live `#[test]`, 3 commented out | |
| `rust/automerge-wasm/test/*.mts` | 9 files + 4 helpers | run under Node/mocha, not wasm-bindgen-test |
| `rust/automerge-wasm/deno-tests/deno.ts` | — | separate Deno smoke test |
| `javascript/test/*.ts` | 18 files + `legacy/*.js` (4 files) | mocha |
| `javascript/packaging_tests/run.mjs` | 13.4 KB | 13 packaging scenarios |
| `.github/workflows/ci.yaml` | 11 jobs | |
| `.github/workflows/release.yaml`, `advisory-cron.yaml`, `dependabot.yaml` | | |
| `scripts/ci/*` | 12 scripts | the actual CI body |
| `flake.nix` | 499 lines | `ci-*` app targets |
| `LICENSE` (root, `javascript/`, `automerge-wasm/`) | 1.0 KB each, byte-identical MIT | |
| `rust/automerge/src/text_diff/LICENSE` | Apache-2.0 | vendored `myers.rs` |

`CONTRIBUTING.md` and `CODE_OF_CONDUCT.md` **do not exist** anywhere in the repo. Contributing guidance lives in `README.md:189` (`## Contributing`) and release procedure in `README.md:197` (`### Releasing`).

`doc/` or `docs/` directories: exactly one — `rust/automerge-c/docs/`, and it contains only `CMakeLists.txt` + `img/brandmark.png` (Doxygen build glue, no prose). `rust/automerge-c/src/doc/{map,list,mark,utils}.rs` is a *source* module, not documentation.

---

## Surface

### 1. Test topology

Five distinct layers, each with a different harness and a different guarantee.

#### 1a. Unit tests inside `rust/automerge/src/`

34 source files carry test code. Distribution (`rust/automerge/src/**`):

```
anonymize.rs:383-388            mod fuzz; mod shape; mod tests
author.rs:245                   mod tests            (proptest-heavy, 2 blocks)
autocommit.rs:1376              mod tests            (is_send::<AutoCommit>())
automerge.rs:44                 mod rollback_tests;
change.rs:406                   mod tests            (proptest)
change_graph.rs:1058            mod tests            (fragments, TestGraphBuilder)
clock.rs:166                    mod tests
exid.rs:203                     mod tests            (proptest)
hydrate.rs:13                   mod tests;
marks.rs:489                    mod tests
automerge/current_state.rs:2    mod tests            (reads ./tests/fixtures/ at :521)
automerge/tests.rs              (commented out at automerge.rs:40-41 — `//mod tests;`)
automerge/rollback_tests.rs:17+ 12 #[test] at file scope
columnar/column_range/delta.rs:94        mod tests
columnar/column_range/opid_list.rs:289   mod tests
columnar/column_range/rle.rs:138         mod tests
columnar/column_range/value.rs:484       mod tests
columnar/encoding/boolean.rs:170         mod tests
columnar/encoding/leb128.rs:23           mod tests
iter/doc.rs:526                         mod tests
iter/list_range.rs:375                  mod tests
legacy/serde_impls/op.rs:282            mod tests
op_set2/meta.rs:127                     mod tests
op_set2/op_set.rs:1612                   mod tests
op_set2/parents.rs:95                   mod tests
op_set2/skip_list.rs:534                mod tests
op_set2/change/batch.rs:1161            mod tests
op_set/mark_index.rs:341                pub(crate) mod tests
op_set/op_iter.rs:1106                  mod tests
storage/bundle.rs:174                  mod test
storage/change/change_op_columns.rs:580 mod tests
storage/columns/column_specification.rs:216 mod tests
storage/parse/leb128.rs:99              mod tests
sequence_tree.rs:540                    mod tests
sync.rs:88                              mod v1_compat_test;
sync.rs:854                             mod tests
transaction/inner.rs:1629               mod tests
transaction/owned_transaction.rs:122    mod tests
```

Notable in-source-only test surfaces that have **no** integration-test equivalent:

- `automerge/src/autocommit.rs:1376-1383` — `fn test_autocommit_is_send()` calls `is_send::<super::AutoCommit>()`; a compile-time `Send` assertion.
- `automerge/src/op_set2/columns.rs:82-99`, `op_set2/op_set.rs:68-81` — `debug_cmp` / `save_checkpoint` helpers, `#[cfg(test)]` only, used for cross-implementation column comparison in `reproduce_clock_cache_bug` (`tests/test.rs:3258`).
- `automerge/src/automerge.rs:580-582`, `:1164-1166` — `save_checkpoint` and `debug_cmp` on `Automerge`, same purpose.
- `automerge/src/iter/keys.rs:1-71` — `KeyIter` / `KeyOpIter` exist **only** under `#[cfg(test)]`; they are test scaffolding inside the production file.
- `automerge/src/sync.rs:73-86` — `#[cfg(test)] use crate::ReadDoc;` plus a test-only import block.
- `automerge/src/storage/parse.rs:148` — `#[cfg(test)] fn with_position(...)`, a test-only constructor for a parser cursor.
- `automerge/src/lib.rs:322-325` — `#[cfg(test)] fn make_rng() -> rand::rngs::SmallRng`, the shared deterministic RNG every proptest/`TestGraphBuilder` uses.

#### 1b. Integration tests in `rust/automerge/tests/`

Each top-level `.rs` in `tests/` is its own binary and its own crate. 293 `#[test]` functions total.

**`test.rs` (4450 lines, 140 tests)** — the CRDT conformance core. `use test_log::test;` at `test.rs:89` shadows the built-in `#[test]` macro for everything *after* line 89, so the first four tests (`test.rs:37`, `:51`, `:61`, `:72`) are plain `#[test]` and the remaining 136 are `test_log`-wrapped (tracing captured per test).

Groups, in file order:

*PatchLog-mismatch regression (0.10.0), `test.rs:37-78`* — `applying_changes_with_patch_log_from_another_document_returns_error_not_panic`, `transaction_with_patch_log_from_another_document_does_not_panic`, `transaction_at_with_patch_log_from_another_document_does_not_panic`, `owned_transaction_with_patch_log_from_another_document_does_not_panic`. All assert `AutomergeError::PatchLogMismatch` / `automerge::PatchLogMismatch` instead of panicking.

*Fuzz-trace minimisations (0.11.0/0.12.0 era), `test.rs:94-826`* — 28 tests. Names encode the invariant: `merge_patches_clear_conflict_after_losing_list_value_is_deleted_from_fuzz_trace`, `bundle_with_mark_columns_decodes_from_fuzz_trace`, `fork_at_rejects_edit_to_object_outside_isolation_from_fuzz_trace`, `historical_owned_transaction_omits_patches_for_unreachable_object_from_fuzz_trace`, `diff_incremental_respects_isolated_heads_from_fuzz_trace`, `fork_at_with_increment_over_conflicted_counter_survives_save_load_from_fuzz_trace`, `transaction_patches_replace_multi_character_string_in_text_from_fuzz_trace`, `merge_patches_replace_multi_character_string_in_text_from_fuzz_trace`, `merge_patches_include_text_element_update_from_fuzz_trace`, `diff_preserves_conflict_after_winning_value_is_deleted_from_fuzz_trace`, `incremental_put_seq_in_text_applies_to_hydrated_value_from_fuzz_trace`, `current_state_diff_with_block_applies_to_hydrated_value_from_fuzz_trace` (**cfg-gated**, see §3), `reverse_diff_of_replaced_lists_applies_to_hydrated_value_from_fuzz_trace`, `unmark_at_end_of_remotely_inserted_conflicted_scalar_in_text_from_fuzz_trace`, `insert_into_replaced_text_run_with_trailing_zero_width_unmark_from_fuzz_trace`, `update_text_after_marking_text_with_hidden_scalar`, `rollback_after_save_load_of_deep_hydrated_root_map_from_fuzz_trace`, `fork_at_preserves_text_encoding`, `load_incremental_into_empty_doc_preserves_utf8_text_encoding`, `spans_match_text_after_merge_of_conflicting_text_overwrites_from_fuzz_trace`, `doc_iter_spans_skip_losing_conflicting_text_overwrites_after_object_shift`, `diff_spans_preserve_marks_on_inserted_text`, `diff_spans_skip_losing_conflicting_text_overwrites`.

The dominant assertion shape is: build doc → `hydrate` → mutate → produce patches → `hydrate.apply_patches(TextEncoding::…, patches)` → `assert_eq!(actual, expected)`. `TextEncoding::UnicodeCodePoint` is the default in most; three tests force `GraphemeCluster` (`:399`) or `Utf8CodeUnit` (`:4289`, `:4318`, `:4339`).

*Merge/CRDT semantics, `test.rs:827-1596`* — 25 tests covering counter increment resolution, concurrent map/list assignment, nested-map non-merge, list insertion tie-breaking by actor id, causality, concurrent deletion, deletion of concurrently-deleted objects.

*Save/load, `test.rs:1597-2247`* — `save_and_restore_empty`, `save_restore_complex1`, `handle_repeated_out_of_order_changes`, `save_restore_complex_transactional`, `delete_only_change`, `save_and_reload_create_object`, `test_compressed_changes` (uses `DEFLATE_MIN_SIZE = 250` at `:2033`), `test_compressed_doc_cols` (per-column deflate bits, `:2048-2049`), `test_change_encoding_expanded_change_round_trip` (inline byte literal, `:2071-2096`), `load_incremental_with_corrupted_tail`, `load_doc_with_deleted_objects`, `insert_after_many_deletes`, `simple_bad_saveload`, `ops_on_wrong_objets`, `save_with_ops_which_reference_actors_only_via_delete`, `save_with_empty_commits`, `make_sure_load_incremental_doesnt_skip_a_load_with_a_common_head`, `zero_length_data`, `allows_empty_keys_in_mappings` (0.5.12), `get_changes_with_hash_of_empty_change_produces_correct_result`, `reproduce_clock_cache_bug` (`:3258-3403`, the longest test, uses `debug_cmp`/`save_checkpoint`).

*Fixture and crash-corpus drivers* —
- `fuzz_crashers` (`test.rs:2210-2219`): `fs::read_dir("./tests/fuzz-crashers")`, then for every file `Automerge::load(&bytes)` **must be `Err`**. A file that loads successfully fails the test.
- `fixture(name)` (`test.rs:2222-2224`): `fs::read("./tests/fixtures/" + name)` — runtime path, not `include_bytes!`.
- `overlong_leb` (`test.rs:2227`): 3 fixtures, `is_err`/`is_err`/`is_ok`.
- `load` (`test.rs:2237`): 3 fixtures, each must load and yield `ROOT.a` → obj → `"b"`.
- `obj_id_64bits` (`test.rs:2256`): 2 fixtures; **permissive** — `if let Ok(doc)` then assert the obj id is not `ROOT`; a load error is accepted.
- `negative_64` (`test.rs:2250`).

*0.11.0/0.12.0 newer surface* — `can_transaction_at` (`:2507`), `can_isolate` (`:2549`), `inserting_text_near_deleted_marks` (`:2619`), `test_load_incremental_partial_load` (`:2638`), `test_get_change_meta` (`:2662`), `get_marks_at_heads` (`:2682`), `conflicting_unicode_text_with_different_widths` (`:2717`), `rollback_with_no_ops` (`:2747`), `rollback_with_several_actors` (`:2775`), `large_patches_in_lists_are_correct` (`:2855`), `diff_should_reverse_deletion_of_object_in_list_correctly` (`:2898`) / `_in_map_correctly` (`:2934`) / `_of_block_in_text_correctly` (`:2969`), `missing_actors_when_docs_are_forked` (`:3006`, issue #897), `has_our_changes` (`:3075`, 0.5.12), `stats_smoke_test` (`:3111`, 0.7.0), `invalid_index` (`:3123`), `test_get_last_local_change_generation` (`:3195`), `test_overwriting_a_conflict` (`:3216`), `merge_panic_after_putting_value_equal_to_initial_value` (`:3405`, issue #1390), `merge_after_noop_then_real_put` (`:3435`, issue #1390), `authorship` (`:3461`, 0.12.0 `Author`).

*Batch-apply atomicity (0.12.0), `test.rs:3528-3781`* — `failed_merge_with_duplicate_sequence_number_does_not_corrupt_save_load`, `duplicate_seq_number_in_batch_change_aborts_whole_batch`, `duplicate_seq_number_within_incoming_batch_is_rejected`, `duplicate_seq_number_changes_are_rejected`, `queued_orphan_with_conflicting_actor_seq_rejects_incoming_batch`, `queued_orphan_need_does_not_block_unrelated_sync_response`.

*Isolate/integrate + encoding (0.11.0), `test.rs:3782-4450`* — `round_trip_change_with_extra_bytes`, `fork_at_current_heads_after_interleaved_actor_changes`, `fork_at_foreign_heads_errors_instead_of_panicking`, `increment_patch_clears_resolved_map_conflict`, `diff_from_integrated_to_isolated_heads_reconstructs_target`, `incremental_diff_survives_isolate_integrate_roundtrip`, `incremental_text_diff_survives_isolate_integrate_roundtrip`, `incremental_diff_discards_edits_inside_deleted_map`, `incremental_counter_diff_survives_isolate_integrate_roundtrip`, `incremental_deep_text_diff_survives_isolate_integrate_roundtrip`, `incremental_sibling_text_diffs_survive_isolate_integrate_roundtrip`, `incremental_patches_survive_nested_edit_and_list_shift_across_isolation`, `incremental_load_preserves_text_encoding_for_all_change_chunk_types`, `incremental_list_conflict_survives_isolate_integrate_roundtrip`, `diff_to_isolated_batch_created_text_applies_to_hydrated_value_from_fuzz_trace`, `diff_exposes_list_object_when_conflict_winner_is_removed`, `transaction_patches_insert_hidden_scalar_into_utf8_text_from_fuzz_trace`, `transaction_patches_split_block_at_normalized_utf8_index`, `transaction_patches_mark_at_normalized_utf8_indexes`, `queued_change_does_not_collide_with_later_local_change`, `patches_expose_surviving_conflict_after_deleting_other_branch_from_fuzz_trace`.

**`text.rs` (1154 lines, 20 `#[test]` + 1 `proptest!`)** — rich-text edit/patch behaviour. Tests: `simple_update_text` (`:17`), `update_text_big_ole_graphemes` (`:33`), `incremental_splice_patches_include_marks` (`:85`), `mark_created_after_insertion` (`:144`), `local_patches_created_for_marks` (`:164`), `spans_are_consolidated_in_the_presence_of_zero_length_spans` (`:298`), `empty_marks_before_block_marker_dont_repeat_text` (`:322`), `insertions_after_noexpand_spans_are_not_marked` (`:351`), `marks_which_cross_optree_boundaries_are_not_double_counted_in_splice_patches` (`:418`), `noexpand_marks_at_the_end_of_text_should_not_emit_marked_patches_on_following_insertions` (`:505`), `expand_marks_are_reported_in_patches` (`:543`), `test_remote_patches_for_marks_with_expand_after` (`:615`), `update_text_change_at` (`:645`), `removed_marks_should_not_appear_in_get_marks` (`:836`, automerge-swift#214), `incorrect_patches_produced_when_isolating_and_integrating` (`:869`, issue #951), `deleting_in_middle_of_multibyte_char_moves_the_cursor_to_after_the_character` (`:924`), `splicing_into_multibyte_characters` (`:944`), `get_marks_agrees_with_marks_at_every_index` (`:1045`), `get_marks_index_counts_the_same_units_as_marks` (`:1091`), `get_marks_at_the_end_of_a_long_text` (`:1122`, 210 000-char text, 0.12.0 perf fix).

The property test is a hand-built action-sequence model, **not** a shrinker over a doc model:

```rust
// rust/automerge/tests/text.rs:658-661
proptest::proptest! {
    #[test]
    fn marks_are_okay(scenario in arb_scenario()) { ... }
}
```

with generators `arb_insert` (`:751`), `arb_delete` (`:755`), `arb_split_block` (`:770`), `arb_add_mark` (`:774`), `arb_action` (`:788`), `arb_scenario` (`:801`, a `pump` state machine) and an `Action` enum. This is the closest thing in the repo to a differential invariant checker and is the single most portable piece of test logic in the tree.

**`diff_marks.rs` (1508 lines, 36 `#[test]`)** — the `spans()` diff algorithm. Tests (in order): `overlapping_marks_remove_one_keep_other`, `overlapping_marks_change_boundaries`, `overlapping_marks_add_third_mark`, `mark_expands`, `mark_contracts`, `mark_shifts_position`, `mark_splits`, `adjacent_marks_merge`, `adjacent_marks_stay_separate`, `different_adjacent_marks`, `mark_on_empty_string`, `mark_on_whitespace`, `removing_all_text_from_marked_span`, `mark_spans_across_block`, `mark_ends_at_block_boundary`, `nested_marks`, `many_marks_on_same_text`, `mark_value_changes_link_url`, `mark_value_changes_color`, `mark_value_type_changes`, `multiple_marks_different_expand_behaviors`, `marks_with_expand_none_at_boundaries`, `marks_on_emoji`, `marks_on_combining_characters`, `unmark_part_of_range`, `unmark_creates_gaps`, `block_properties_change_with_marks`, `idempotent_update_spans`, `alternating_mark_changes`, `complex_unicode_text`, `block_with_marked_content`, `empty_spans_between_marks`, `marks_with_different_values_same_name`, `update_spans_with_only_blocks`, `marks_survive_block_updates`, `update_spans_which_inserts_at_the_end_of_expand_mark_doesnt_generate_mark_changes` (`:1473`, asserts `change.decode().operations.len() == 2`).

**`batch_insert.rs` (1065 lines, 46 `#[test]`)** — 0.8.0 `batch_create_object` / `init_root_from_hydrate` / batch `splice`. Covers flat map, nested maps, overwrite of existing key, flat list, list of nested objects, scalar rejection (`:130`), insert at end / middle of list, batch put over existing list element, text objects in maps and lists, deep nesting, mixed nesting, save/load, merge, multiple sequential batch inserts, insert into pre-existing map/list, equality with `hydrate` output, use inside a `Transaction`, transaction rollback, empty map/list/text, all scalar types, "equivalent to individual ops", patch generation, `splice` patches for text, list-of-lists, nested overwrite, `batch_init_map_*` (6), `splice_*` (10: scalars, objects, mixed, delete+insert, delete-only, text, deep, save/load, merge), and `batch_create_object_rejects_map_key_in_text` (`:1038` — the 0.11.0 breaking change).

**`block_tests.rs` (946 lines, 19 `#[test]`)** — `update_spans` / `split_block` / `join_block` / `update_block` (0.5.10): `update_blocks_change_block_properties`, `update_blocks_updates_text`, `update_blocks_updates_marks`, `update_blocks_noop`, `update_blocks_updates_text_and_blocks_at_once`, `text_complex_block_properties`, `update_spans_delete_attribute`, `marks_on_spans_respect_heads`, `marks_in_spans_cross_block_markers`, `test_mark_behavior_on_delete_insert`, `spans_consolidates_marks_which_are_empty_due_to_deleted_marks`, `spans_consolidates_marks_with_deleted_marks_followed_by_empty_marks`, `spans_consolidates_marks_with_empty_marks_followed_by_deleted_marks`, `update_spans_diffs_marks`, `update_spans_uses_expand_config`, `diff_emits_block_updates`, `diff_exposes_rich_text_when_reversing_deletion`, `merge_produces_block_insertion_diffs`, `test_splice_with_mark` (issue #935).

**`text_encoding.rs` (639 lines, 15 `#[test]`)** — the encoding-parameterised harness. Defines a local `enum Encoding { UnicodeCodePoint, Utf8CodeUnit, Utf16CodeUnit, GraphemeCluster }` with `From<Encoding> for automerge::TextEncoding` (`:58-66`) and `Display` (`:69`), an `Expected<T>` enum with `Always(T)` and `ByEncoding { code_point, utf8, utf16, grapheme }` (`:89-118`), and a `Scenario` struct with `run` (`:121`, infallible) and `run_fallible` (`:146`, `Result`-returning) — each loops over all four encodings. The 15 tests: `length` (`:184`), `splice_text` (`:199`), `mark` (`:219`), `unmark` (`:248`), `cursors` (`:274`), `get` (`:301`), `put` (`:325`), `insert` (`:344`), `delete` (`:363`), `split_block` (`:382`), `patch_put_text` (`:410`), `patch_insert` (`:457`), `patch_splice_text` (`:502`), `patch_delete` (`:547`), `patch_mark` (`:592`). Effective coverage: 15 scenarios × 4 encodings.

**`rich_text_fuzz_crash.rs` (243 lines, 9 `#[test]`)** — the only integration test file using `include_bytes!`: `load_rejects_historical_zero_width_mark_end_before_begin` (`:222-223`) and `rescue_recovers_snapshot_from_historical_zero_width_mark_order` (`:232-233`) both `include_bytes!("fixtures/broken_zero_width_mark.automerge")`. Others: `splice_scalar_into_marked_text` (`:25`), `splice_string_into_marked_text` (`:47`), `zero_width_unmark_on_empty_text_sync_from_fuzz_trace` (`:64`, minimised from `fuzz/corpus/trace/crashes/crash-00000000.amtrace`), `zero_width_mark_on_empty_text_from_fuzz_trace` (`:95`), `zero_width_mark_does_not_leak_to_later_text_object_from_fuzz_trace` (`:118`), `splice_text_at_length_over_conflicted_element_from_fuzz_trace` (`:164`), `mark_within_single_multi_width_element_from_fuzz_trace` (`:194`).

**`convert_string_to_text.rs` (72 lines, 3 `#[test]`)** — 0.5.2 `LoadOptions` string→text migration: `test_strings_in_maps_are_converted_to_text`, `test_strings_in_lists_are_converted_to_text`, `test_does_not_add_size_when_strings_are_not_converted`.

**`test_save_load_orphans.rs` (84 lines, 3 `#[test]`)** — `save_orphaned_changes` (`:30`), `discard_orphans` (`:49`), `load_incremental_change_without_deps_throws` (`:72`), all built on a `struct Orphans` fixture built by `doc_with_orphans()` (`:9`).

**`test_mark_patches.rs` (41 lines, 1 `#[test]`)** — `mark_patches_at_end_of_text` (`:9`), the 0.5.10 fix.

#### 1c. Other crates' integration tests

- `rust/automerge-cli/tests/integration.rs` — 2 live tests: `import_export_isomorphic` (byte-for-byte stdin→stdout round-trip through `duct`), `anonymize_scrubs_a_document_from_stdin`. Three more are commented out (`import_stdin`, `export_stdout`, `import_change_export`).
- `rust/hexane/tests/pending.rs` — 6 tests, **all `#[ignore]`d**, all documenting live bugs. Header comment (`pending.rs:1-11`) says each names one defect, run with `cargo test -p hexane --test pending -- --ignored`. The six: `resume_rejects_a_foreign_column` (`:25`), `find_by_value_finds_nulls` (`:51`), `splice_runs_enforces_the_domain_like_insert_runs` (`:64`), `rle_load_rejects_a_wrapped_length` (`:89`), `a_default_iter_repositions_without_panicking` (`:117`), `load_with_rejects_an_out_of_domain_fill` (`:138`).
- `rust/automerge-test` — no `tests/`; it *is* the shared assertion library (`automerge-test/Cargo.toml`), consumed as a dev-dependency by `automerge` (`rust/automerge/Cargo.toml:47`).

#### 1d. `wasm-bindgen` tests

There are **no** `#[wasm_bindgen_test]` functions in the tree. `automerge-wasm` declares `wasm-bindgen-test` and `wasm-bindgen-futures` as dev-dependencies (`rust/automerge-wasm/Cargo.toml:63-65`) but the actual tests are TypeScript, run in Node under mocha against the built `.wasm`:

`rust/automerge-wasm/package.json:44` — `"test": "tsc --noEmit && mocha --loader=ts-node/esm test/**/*.mts"`.

Files: `test/test.mts`, `marks.mts`, `readme.mts`, `update_text.mts`, `isolate.mts`, `blocks.mts`, `cursor.mts`, `diff.mts`, `apply.mts`, plus `test/helpers/{columnar,common,encoding,sync}.mjs`. Driver: `scripts/ci/wasm_tests` → `npm install && npm run build && npm run test`.

`rust/automerge-wasm/deno-tests/deno.ts` is a separate Deno smoke test, not wired into `scripts/ci/run`.

#### 1e. JS tests

`javascript/package.json:41` — `"test": "ts-mocha --loader=ts-node/esm --experimental-specifier-resolution=node --type-check test/*.ts"`. Note the glob `test/*.ts`: `test/legacy/*.js` is **not** directly run.

| File | Top-level `describe` structure |
|---|---|
| `test/legacy_tests.ts` (67.9 KB) | `initialization `, `sequential use`, `concurrent use`, `saving and loading`, `history API`, `changes API` |
| `test/sync_test.ts` (48.5 KB) | `with docs already in sync`, `with diverged documents`, `with false positives` (brute-force Bloom-filter collision search, `sync_test.ts:556-559`), `protocol features`, `read-only sync` (0.9.0) |
| `test/patches.ts` (30.5 KB) | `the patchCallback`, `the diff function`, `the applyPatches function` → `block marker patches` |
| `test/proxies.ts` (9.8 KB) | recursive document, `__proto__ handling`, `List Iterators`, `List indexOf`, `List splice`, `map proxy`, `list proxy`, `structuredClone support`, `Falsy values are respected`, `Object.prototype toString/valueOf/hasOwnProperty` |
| `test/basic_test.ts` | `basics`, `explicitly allowing missing dependencies when loading`, `merge`, `clone`, `emptyChange`, `proxy lists`, `getObjectId`, `load`, `diff`, `saveSince`, path-immutability, `hasHeads`, `topoHistoryTraversal`, `inspectChange`, `stats`, `ImmutableString` |
| `test/block_test.ts` (12.6 KB) | `block`, `updateSpans`, `RawString` block attrs, `Automerge.view` historical marks |
| `test/text_test.ts` | `Automerge.Text`, `with initial value`, `updateText` |
| `test/cursors.ts` | `cursors`, `Automerge.view` |
| `test/change_at.ts` | `changeAt` |
| `test/change_time.ts` | `change`, `emptyChange` timestamps |
| `test/extra_api_tests.ts` | `basics` (load incrementally, …) |
| `test/new-change-api.ts` | `Unstable change tests` |
| `test/fragments_test.ts` | `the fragments API` (0.11.0 experimental) |
| `test/bundle_test.ts` | `the bundle format` (0.7.0) |
| `test/marks.ts` | `marks` |
| `test/conflicts.ts` | `conflicts` |
| `test/error.ts` | `Automerge errors` |
| `test/next_test.ts` | `The next export` (2.0 back-compat shim) |
| `test/helpers.ts` | shared helpers |
| `test/legacy/{columnar,common,encoding,sync}.js` | vendored JS-era conformance suites, imported by the TS tests |

Packaging tests: `javascript/packaging_tests/run.mjs` drives 13 scenarios in subdirectories (`node_esm_slim`, `node_cjs_fullfat`, `webpack_{cjs,esm}_{slim,fullfat}`, `vite_{slim,fullfat,iife_fullfat}`, `workerd_{slim,fullfat}`, `iife`, …).

#### 1f. Fuzzing

- `rust/automerge/fuzz/Cargo.toml` — crate `automerge-fuzz` v0.0.0, `publish = false`, `[package.metadata] cargo-fuzz = true`, and crucially its own `[workspace] members = ["."]` (`:17-18`) so it is **excluded** from the `rust/` workspace. One target: `load`.
- `rust/automerge/fuzz/fuzz_targets/load.rs` — the only fuzz target. It synthesises a *document chunk* around arbitrary bytes:

```rust
// rust/automerge/fuzz/fuzz_targets/load.rs:16-22
fn add_header(typ: u8, data: &[u8]) -> Vec<u8> {
    let mut input = vec![u8::from(typ)];
    leb128::write::unsigned(&mut input, data.len() as u64).unwrap();
    input.extend(data.as_ref());
    let hash_result = Sha256::digest(input.clone());
    let array: [u8; 32] = hash_result.into();
    let mut out = vec![133, 111, 74, 131, array[0], array[1], array[2], array[3]];
    out.extend(input);
    out
}
```

`fuzz_target!` then calls `Automerge::load(&doc.bytes)` and discards the result (`:34-36`). The invariant under test is purely "must not panic on hostile input".
- `.gitignore` in `fuzz/`: `target`, `corpus`, `coverage` (`:1-3`) — so the corpus is **not** committed; only the crashers are, and they are committed to `rust/automerge/tests/fuzz-crashers/`.
- `hexane` has its own in-crate fuzzers: `rust/hexane/src/splice_fuzz.rs` (19.6 KB) plus a `deep_fuzz` feature (`rust/hexane/Cargo.toml:17`) that is "skipped by default so `cargo test` stays fast".
- `rust/hexane/proptest-regressions/tests.txt` (2.0 KB) is a committed proptest seed file — real regression seeds for the column codecs.
- Hexane also claims golden wire-format fixtures: `rust/hexane/README.md:256-262` — "The byte format **is** the automerge document format, so it is frozen. The test suite pins it with golden fixtures — byte-exact expected encodings for every codec". Those goldens are **in-code** (`rust/hexane/src/tests.rs`, 193 KB), not files on disk. [INFERENCE] based on the absence of any fixture directory under `rust/hexane/`.

### 2. Fixture corpus

`rust/automerge/tests/fixtures/` — 9 files, 1162 bytes total.

| File | Bytes | Used by | Expectation |
|---|---|---|---|
| `counter_value_is_ok.automerge` | 63 | `test.rs:2233`, `src/automerge/current_state.rs:527` | loads OK; also loaded with `OnPartialLoad::Error` + `VerificationMode::Check` |
| `counter_value_has_incorrect_meta.automerge` | 63 | `test.rs:2229` | `load` is `Err` — value metadata says 2 but LEB is 1 byte with a trailing 0 (`test.rs:2228`) |
| `counter_value_is_overlong.automerge` | 63 | `test.rs:2231` | `load` is `Err` — 2-byte LEB where 1 would suffice (`test.rs:2230`) |
| `two_change_chunks.automerge` | 177 | `test.rs:2244` | loads; `ROOT.a` → map → `"b"` |
| `two_change_chunks_compressed.automerge` | 192 | `test.rs:2245` | same, DEFLATE-compressed |
| `two_change_chunks_out_of_order.automerge` | 177 | `test.rs:2246` | same, chunk order reversed |
| `64bit_obj_id_change.automerge` | 73 | `test.rs:2259` | permissive: either `Err`, or the resulting map id ≠ `ROOT` (opId 2^42 truncates to 0 in 32 bits, `test.rs:2257-2258`) |
| `64bit_obj_id_doc.automerge` | 147 | `test.rs:2265` | same, as a document chunk rather than a change chunk (`test.rs:2264`) |
| `broken_zero_width_mark.automerge` | 207 | `rich_text_fuzz_crash.rs:223`, `:233` | `load` is `Err` containing `"invalid mark operation order"`; `Automerge::rescue` recovers the value (0.11.0) |

`rust/automerge/tests/fuzz-crashers/` — 8 files, 893 bytes total. All must fail to load (`test.rs:2210-2219`).

| File | Bytes | Name encodes |
|---|---|---|
| `crash-da39a3ee5e6b4b0d3255bfef95601890afd80709` | 10 | `da39a3ee…` is the SHA-256 of the empty string; the file is 10 bytes — the empty chunk `magic‖checksum‖typ‖len` |
| `incorrect_max_op.automerge` | 126 | `max_op` column inconsistency |
| `invalid_deflate_stream.automerge` | 123 | DEFLATE payload that does not inflate |
| `missing_actor.automerge` | 126 | `actor` column references an absent actor |
| `overflow_in_length.automerge` | 182 | length field overflow |
| `too_many_deps.automerge` | 134 | dependency count above the cap |
| `too_many_ops.automerge` | 134 | operation count above the cap |
| `action-is-48.automerge` | 58 | out-of-range `action` enum discriminant |

**Format.** Every `.automerge` file and the `interop/exemplar` file begin with the 4-byte magic `85 6f 4a 83` (hex), confirmed by reading `tests/fixtures/counter_value_is_ok.automerge` raw and by `tests/test.rs:2072-2076`:

```rust
// rust/automerge/tests/test.rs:2071-2076
let change_bytes: Vec<u8> = vec![
    0x85, 0x6f, 0x4a, 0x83, // magic bytes
    0xb2, 0x98, 0x9e, 0xa9, // checksum
    …
```

The `fuzz/fuzz_targets/load.rs:16-22` code proves the layout `magic(4) ‖ checksum(4) ‖ type_byte(1) ‖ LEB128(len) ‖ payload`, with `checksum = SHA-256(type‖len‖payload)[0..4]` and `type = 0` meaning a document chunk. [INFERENCE] the exact checksum input framing for *all* chunk types, since the fuzz target is the only place it is spelled out in the repo.

`interop/exemplar` (406 B) is the cross-platform interop document described in `interop/README.md:5-19`: `title` (emoji string), `notes` (Text object), `timestamp` (1941-04-26T08:17:00.123Z), `location` (URL scalar), `counter` (5), `int` (−4), `uint` (18446744073709551615), `fp` (3.14159267), `bytes` (`0x856f4a83`), `bool` (true). The README pins the expected `automerge export` JSON at `interop/README.md:23-40`. This is the **only** cross-implementation conformance asset in the repository.

### 3. Feature and CI matrix

#### Cargo features

`rust/automerge/Cargo.toml:10-18`:

```toml
[features]
wasm = ["js-sys", "wasm-bindgen", "web-sys", "getrandom/wasm_js", "hexane/wasm"]
utf8-indexing = []
utf16-indexing = []
# Whether to enable "slow path" assertions which check that various invariants hold
# should only be enabled when running tests
slow_path_assertions = ["hexane/slow_path_assertions"]
```

`rust/hexane/Cargo.toml:14-19`:

```toml
[features]
wasm = ["web-sys"]
slow_path_assertions = []
# Deep/expensive fuzz tests, skipped by default so `cargo test` stays fast.
deep_fuzz = []
bijou64 = ["dep:bijoux"]
```

`automerge-wasm` selects `features = ["wasm", "utf16-indexing"]` on its `automerge` dependency (`rust/automerge-wasm/Cargo.toml:38`).

**Nothing in the repo enables both `utf8-indexing` and `utf16-indexing`.** One integration test is explicitly excluded when either is on: `tests/test.rs:420` `#[cfg(not(any(feature = "utf16-indexing", feature = "utf8-indexing")))]`. The mutual exclusion is therefore enforced by convention, not by `compile_error!`. [INFERENCE] from absence of any `compile_error!` in the tree.

`benchmark-battery` has a single non-default feature: `memory` (`rust/benchmark-battery/Cargo.toml:5-7`).

`automerge-wasm` has `default = []` and a commented-out `wee_alloc` (`rust/automerge-wasm/Cargo.toml:26-28`).

#### Workspace members

`rust/Cargo.toml:1-14` — `resolver = "2"`, members: `automerge`, `automerge-c`, `benchmark-battery`, `automerge-cli`, `automerge-test`, `automerge-wasm`, `edit-trace`, `hexane`. Profiles: `[profile.release] lto = true, codegen-units = 1` (`:16-19`), `[profile.bench] debug = true` (`:21-22`). `rust/hexane/Cargo.toml:33-34` also declares `[profile.release] debug = true`, which is inert for a workspace member (root profiles win).

| Crate | Version | Edition | `rust-version` | License | Kind | Path |
|---|---|---|---|---|---|---|
| `automerge` | 0.12.0 | 2021 | **1.90.0** | MIT | lib | `rust/automerge/Cargo.toml:2-9` |
| `hexane` | 1.0.0-alpha.5 | 2021 | 1.90.0 | MIT | lib, `bench = false` | `rust/hexane/Cargo.toml:2-9`, `:12-13` |
| `automerge-test` | 0.12.0 | 2021 | 1.90.0 | MIT | lib | `rust/automerge-test/Cargo.toml:2-8` |
| `automerge-wasm` | 0.1.0 | 2021 | 1.90.0 | MIT | `cdylib`+`rlib`, name `automerge_wasm` | `rust/automerge-wasm/Cargo.toml:3-13`, `:30-33` |
| `automerge-c` | 0.2.2 | 2021 | 1.90.0 | MIT | `staticlib`, lib name `automerge_core` | `rust/automerge-c/Cargo.toml:2-16` |
| `automerge-cli` | 0.1.0 | 2021 | 1.90.0 | MIT | bin `automerge` | `rust/automerge-cli/Cargo.toml:2-14` |
| `edit-trace` | 0.1.0 | 2021 | — | MIT | bin + criterion bench `main` | `rust/edit-trace/Cargo.toml:2-4`, `:14-21` |
| `benchmark-battery` | 0.1.0 | 2021 | **1.89.0** | MIT | bin | `rust/benchmark-battery/Cargo.toml:2-7` |
| `automerge-fuzz` | 0.0.0 | 2021 | — | — (`publish = false`) | bin `load`, **not a member** | `rust/automerge/fuzz/Cargo.toml:2-5`, `:17-24` |

Key dependencies of the core crate (`rust/automerge/Cargo.toml:20-43`): `cfg-if 1.0`, `flate2 ^1.0.22` with `default-features = false, features = ["zlib-rs"]` (pure-Rust DEFLATE; wasm-compatible — 0.11.0 changelog), `getrandom 0.4`, `hex ^0.4.3`, `hexane` (path, `1.0.0-alpha.5`), `itertools 0.15.0`, `leb128 ^0.2.5`, `rustc-hash ^2.1.1`, `serde ^1.0` (derive), `sha2 ^0.11.0-rc.5` (**release candidate**), `smol_str 0.3` (serde), `thiserror ^2.0.12`, `tinyvec ^1.5.1` (alloc), `tracing ^0.1.29`, `unicode-segmentation 1.10.1`; optional `js-sys`, `wasm-bindgen ^0.2`, `web-sys ^0.3.55` (console); `rand ^0.10` is declared `optional = false`, i.e. **always** built.

Dev-dependencies (`rust/automerge/Cargo.toml:45-53`): `automerge-test` (path), `maplit ^1.0`, `pretty_assertions 1.0.0`, `prettytable 0.10.0`, `proptest ^1.7.0` (`default-features = false, features = ["std"]`), `serde_json ^1.0.73` (`float_roundtrip`), `test-log ^0.2.10` (`trace`), `tracing-subscriber ^0.3`.

`automerge-wasm` pins `wasm-bindgen = "= 0.2.127"` exactly (`rust/automerge-wasm/Cargo.toml:47-49`).

`hexane` dev-deps include `divan 0.1.15` for benches (`rust/hexane/Cargo.toml:26-29`).

#### CI jobs

`.github/workflows/ci.yaml` — 11 jobs, all on `push`/`pull_request` to `main`. Every Linux job installs Nix (`cachix/install-nix-action@v31`) and runs a `nix run .#<target>`; the Windows job is native (`dtolnay/rust-toolchain@1.90.0` + `./scripts/ci/build-test`).

| Job | Command | Script |
|---|---|---|
| `fmt` | `nix run .#ci-fmt` | `scripts/ci/fmt` → `cd rust && cargo fmt -- --check` |
| `lint` | `nix run .#ci-lint` | `scripts/ci/lint` → `find . -name "*.rs" -not -path "./target/*" -exec touch {} +` then `cargo clippy --all-targets --all-features -- -D warnings` |
| `docs` | `nix run .#ci-rust-docs` | `RUSTDOCFLAGS="-D rustdoc::broken-intra-doc-links -D warnings" cargo doc --no-deps --workspace --document-private-items` |
| `cargo-deny` | matrix `advisories` (continue-on-error) / `bans licenses sources` | `scripts/ci/advisory` |
| `build_wasm` | `nix run .#ci-wasm-tests` | `scripts/ci/wasm_tests` |
| `js_tests` (needs `build_wasm`) | `nix run .#ci-js-tests` | `scripts/ci/js_tests` |
| `node_18_packaging_test` (needs `build_wasm`) | `nix run .#ci-node18-packaging-test` | `scripts/ci/node_18_packaging_test` |
| `linux` | `nix run .#ci-build-test` | `scripts/ci/build-test` |
| `macos` | `nix run .#ci-build-test` | same script |
| `windows` | `./scripts/ci/build-test` (bash) | same script |

`scripts/ci/build-test` is the whole Rust test gate:

```bash
# scripts/ci/build-test:4-10
pushd rust
RUST_LOG=error cargo test -p automerge --features slow_path_assertions
RUST_LOG=error cargo test -p automerge-test
RUST_LOG=error cargo test -p automerge-c
RUST_LOG=error cargo test -p automerge-cli
RUST_LOG=error cargo test -p automerge-wasm
popd
```

Two consequences proven from that file: **`-p hexane` is never tested by CI**, and `--features slow_path_assertions` is added only for `-p automerge` (where it forwards to `hexane/slow_path_assertions`).

`scripts/ci/js_tests` (`:8-13`): `npm install` → `node scripts/build.mjs` → `npm test` → `npm run packaging-tests`.

`scripts/ci/wasm_tests` (`:6-9`): `npm install` → `npm run build` → `npm test` in `rust/automerge-wasm`.

`scripts/ci/node_18_packaging_test` runs only the `node_cjs_fullfat` packaging scenario, using `fnm exec --using 18` when available; exits 0 with a warning when neither Node 18 nor `fnm` is present (`:19-22`). Rationale and the WebCrypto polyfill history are in `javascript/HACKING.md:192-219` — `getrandom` removed its Node-18 CommonJS polyfill, so the project prepends its own to the generated `.cjs` in `javascript/build.mjs::prependWebcryptoPolyfill`.

`scripts/ci/run` (`:5-15`) is the local superset: `fmt`, `fmt_js`, `lint`, `build-test`, `rust-docs`, `advisory`, `wasm_tests`, `js_tests`, `node_18_packaging_test`, `cmake-build Release static`.

Flake entry points (`flake.nix:305-426`): `ci-fmt`, `ci-lint`, `ci-rust-docs`, `ci-cargo-deny`, `ci-build-test`, `ci-wasm-tests`, `ci-js-tests`, `ci-node18-packaging-test`, `release-js-build`, `release-js-docs`, `release-js-publish`, and the aggregators `ci-linux` (`flake.nix:384-406`, runs the same list with `ci-cargo-deny advisories || true`) and `ci-host` (`:408-410`, build-test only, used by the macOS job). Toolchain: `nixpkgs/nixos-26.05` for main, `nixpkgs-node18.url = "nixpkgs/nixos-23.11"` pinned for Node 18 (`:5-7`); Node 26 for dev, 24 for CI, 18 and 20 retained (`:44-48`); CI Rust toolchain derived from `rust/rust-toolchain.toml` with `clippy` + `rustfmt` extensions (`:50-52`).

`.github/workflows/release.yaml` — on GitHub `release: published`: build + `npm publish` of the JS package (`--tag next` for prereleases), and deploy JS API docs to `gh-pages`.
`.github/workflows/advisory-cron.yaml` — nightly `0 18 * * *` cargo-deny matrix.
`.github/dependabot.yaml` — weekly updates for cargo (`/rust`), github-actions (`/.github/workflows/`), npm (`/javascript`).

#### `cargo deny` policy

`rust/deny.toml:68` — `allow = ["MIT", "Apache-2.0", "Apache-2.0 WITH LLVM-exception"]`, `confidence-threshold = 0.8` (`:73`). Per-crate exceptions (`:76-95`): `unicode-ident` (MIT/Apache-2.0/Unicode-3.0), `cbindgen` (MPL-2.0), `zlib-rs` (Zlib), and five crates pulled in by `resvg` used only by `benchmark-battery` (`slotmap`, `arrayref`, `tiny-skia`, `tiny-skia-path`). `[bans] multiple-versions = "deny"` (`:133`), `wildcards = "allow"` (`:135`), skip list for `itertools@0.13.0` and `winnow@0.7.15` (`:155-163`). `[sources] allow-registry = ["https://github.com/rust-lang/crates.io-index"]`, `allow-git = []` (`:183-185`) — **no git dependencies are permitted**.

### 4. Changelog: public API change timeline

`rust/CHANGELOG.md` is workspace-scoped but every entry concerns the `automerge` crate. It is the port's compatibility contract. Full timeline, oldest last, only API-visible items retained.

**0.5.0** — added `Cursor`; removed `OpObserver` in favour of a patch API (`<method>_log_patches` taking a `PatchLog`; `Automerge::make_patches` turns the log into `Vec<Patch>`); added `AutoCommit::{diff, diff_incremental}`; added `Transactable::change_at` and `AutoCommit::{isolate, integrate}`.

**0.5.1** — `AutoCommit` and `PatchLog` became `Send`; `Automerge::load_incremental_log_patches` made `pub`.

**0.5.2** — added `Automerge::load_with_options` / `AutoCommit::load_with_options`, deprecated `load_with`; new option to convert `ScalarValue::Str` → `ObjType::Text` on load; exposed `VerficationMode` (sic).

**0.5.3** — added `ReadDoc::get_marks`; `generate_sync_message` now always returns at least one message.

**0.5.4** — sync protocol now sends the entire document in the first message if the peer has nothing (backwards compatible).

**0.5.5** — sync protocol back-compat fix (0.5.4 peers could emit messages older peers could not parse).

**0.5.6** — added `Transactable::update_text` (diff a text field into splice ops).

**0.5.7** — `Read::get_marks` honoured the passed heads.

**0.5.8** — transaction rollback no longer panics on error; marks correct at non-current heads; `LoadOptions::migrate_strings` no-ops when there is nothing to convert.

**0.5.9** — fix loading a document containing empty commits; diff performance.

**0.5.10** — block-marker API: `ReadDoc::{spans, spans_at}`, `Transactable::{split_block, join_block, update_block}`, `Transactable::update_spans`. Explicitly documented as under-documented, written to support the JS implementation.

**0.5.11** — actor IDs were written incorrectly to the save format, making documents unloadable.

**0.5.12** — allow empty keys in maps; added `SyncState::has_our_changes`; added `ReadDoc::stats`; added the `utf-16-indexing` feature flag for wasm32.

**0.6.0** — `Automerge::new_with_encoding` sets the text encoding used for indices; cursor API can point at start/end and configure behaviour when the referenced character is deleted.

**0.6.1** — `get_marks` no longer returns removed marks as `ScalarValue::Null`.

**0.7.0** — *the large one.* Introduces using the on-disk columnar compression at runtime (≈100× lower steady-state memory; **no API change**). Explicitly labelled "an exhaustive list":
- *Added*: `ReadDoc::iter` and `ReadDoc::iter_at`; `{AutoCommit, Automerge}::apply_changes_batch`; `{AutoCommit, Automerge}::bundle` (experimental); `{AutoCommit}::is_empty()`; `{Automerge, AutoCommit}::{get_changes_meta, get_change_meta_by_hash}`; `Transactable::update_spans` now takes an `UpdateSpansConfig`; `Change::actors`; `MarkSet::non_deleted_marks`; `Stats::{num_actors, cargo_package_name, cargo_package_version, rustc_version}`.
- *Changed*: `Automerge::{get_last_local_change, get_change, get_change_by_hash}` now return an owned `Change` (changes are no longer stored, decompressed on demand); `hydrate::Text::new` and `hydrate::Value::text` take `TextEncoding` instead of `TextRepresentation`; `hydrate::Value::{apply_patches, apply}` take `TextEncoding`; `MapRangeItem::key` is `Cow<'a, str>` not `&'a str`; `ListRangeItem`/`MapRangeItem` lost their `R: RangeBound` parameter; their `value` field is `ValueRef` not `Value`; `Span::Text` has named fields; `Mark` has no lifetime parameter and `Mark::into_owned` is gone; `Mark::data` became `Mark::{name, value}`; `MarkData` removed.
- *Removed*: `{AutoCommit, Automerge}::visualise_optree`; `{ListRangeItem, MapRangeItem}::id`; the `TextRepresentation` type entirely, and with it `AutoCommit::{get_text_rep, set_text_rep, with_text_rep}`, the `TextRepresentation` argument on `Automerge::{transact_and_log_patches, transact_and_log_patches_with, current_state, diff}`, and the `TextRepresentation` argument of `PatchLog::new`.

**0.7.1** — sync-loop fix; MSRV raised to 1.89 (inherited from `smol_str 0.3.4`).

**0.7.2** — sync message processing performance (#1218); reduced peak memory on load (#1184).

**0.7.3** — peers that lost sync state no longer silently revert to v1 sync; added `{Automerge, AutoCommit}::diff_obj` (patches for a single object).

**0.7.4** — patches in documents containing rich text were malformed.

**0.8.0** — added `Transactable::batch_create_object` (create a whole `hydrate::Value` in one call) and `Transactable::init_root_from_hydrate`; **breaking**: `Transactable::splice` now takes an iterator of `Into<hydrate::Value>` instead of `IntoIterator<ScalarValue>`; fixed O(n²) in `load_incremental`; slow debug assertions moved behind the `slow_path_assertions` feature flag.

**0.9.0** — read-only sync: `sync::State::new_read_only()`, `sync::State::set_read_only()`, `sync::State::is_peer_read_only()`, new `sync::MessageFlag` enum (`MessageV1`, `MessageV2`, `SyncReset`, `ReadOnly`). **Breaking**: `sync::Capability` split into `sync::MessageFlag` (per-message wire flags) and a smaller `sync::Capability` (`MessageV1`, `MessageV2` only) — `Unknown`, `SyncReset`, `ReadOnly` moved to `MessageFlag`; `sync::Message::supported_capabilities` renamed to `sync::Message::flags` and retyped from `Option<Vec<Capability>>` to `Option<Vec<MessageFlag>>`; `sync::State` gained public fields `read_only`, `peer_read_only`, `needs_reset`.

**0.10.0** — **breaking**: `Automerge::transaction_log_patches`, `Automerge::transaction_at`, and `Automerge::into_transaction` now return `Result<_, PatchLogMismatch>` when handed a patch log from another document, instead of panicking.

**0.11.0** —
- *Breaking*: MSRV 1.90; `Change::message` returns `Option<&str>` not `Option<&String>`; loading now **rejects** documents whose rich-text mark-end operations precede their mark starts (use `Automerge::rescue` to recover); batch object creation rejects map-key ops inside text objects; `Transactable::splice` on a text object accepts only string scalar values.
- *Added*: `Automerge::anonymize`, `AutoCommit::anonymize`, `automerge::anonymize::anonymize` (best-effort, explicitly **not** cryptographic); `Automerge::rescue`; experimental, documentation-hidden `fragments`, `get_fragment`, `bundle_fragments` on `Automerge` and `AutoCommit`.
- *Changed*: text/span/mark reads 69–94 % faster on large documents; DEFLATE moved to the pure-Rust `zlib-rs` backend.

**0.12.0** —
- *Breaking*: removed the obsolete `optree-visualisation` Cargo feature and its optional `dot` dependency; `ChangeMetadata` and `ExpandedChange` gained an `author` field (breaks exhaustive destructuring); `AutomergeError` gained a `DuplicateAuthor` variant.
- *Added*: the `Author` type — opaque bytes with hex parsing, formatting and serde. `Automerge`/`AutoCommit` gained `with_author`, `set_author`, `get_author`, `get_authors`, `get_actors_for_author`, `get_author_for_actor`; `LoadOptions::author`. Changing the author generates a fresh actor id. Author assignments live in the extra bytes of an actor's first change and survive merge and save/load. `Change::author` reads an assignment from an individual change; later changes from the same actor need not carry one. `get_changes_meta` / `get_change_meta_by_hash` resolve authorship through the actor→author map. Added `Value::as_scalar`, `Value::as_objtype`, and `as_bytes`/`as_str`/`as_i64`/`as_u64`/`as_f64`/`as_bool` on both `Value` and `ScalarValue`.
- *Changed*: batch change application now de-duplicates incoming changes and validates duplicate actor sequence numbers up front, against both queued and incoming changes; it also rejects duplicate author assignments.
- *Deprecated*: `Value::to_scalar` and the `to_*` family, in favour of `as_*` (behaviour unchanged).
- *Fixed*: constant-time object-created-in-current-transaction check (was scanning all pending ops); patches exposing an existing text object now carry rich-text marks, embedded blocks and block contents instead of flattening to plain text; list insertion positioning when a counter increment precedes a trailing insert (could corrupt op grouping and break `get_changes`); fragment `checkpoints` no longer include the fragment's own head (head stays in `members`); `load_with_options` on empty input now honours the requested text encoding.

**Unreleased** (top of the file, `rust/CHANGELOG.md:1-8`) — `ReadDoc::get_marks` is much faster (100 000-char text: 9 ms → 1.6 µs) and now uses the same units as `length`, `marks` and `get` (they disagreed under some text encodings). The crate version in `Cargo.toml` is still `0.12.0`, so **the working tree is ahead of its own version bump**.

`rust/hexane/CHANGELOG.md` — only three entries: `1.0.0-alpha.2` (7 July 2026), `0.2.1` (25 March 2026), `0.2.0` (6 March 2026). The crate version is `1.0.0-alpha.5`, so **alpha.3, alpha.4 and alpha.5 are undocumented**. alpha.2 is itself a large breaking change: the 0.2-era `ColumnData<C>` cursor API removed, `hexane::v1::Column` promoted to `hexane::Column`, `PrefixColumn`/`PrefixIter` yield `PrefixedValue` (`{value, prefix(), total()})` instead of tuples, `PrefixSeek` is now `{pos, delta, pv}`, `PrefixColumn::{seek, get_delta, get_value, value_iter}` removed, `prefix_delta` renamed `sum_range`, `Column::with_max_segments`/`load` reject budgets below 2. `rust/hexane/V1_MIGRATION.md` (361 lines) is the porting table for the `automerge` side of that migration and is the only place in the repo that maps the v0 encoder API to v1 column-by-column.

`javascript/CHANGELOG.md` — one entry, `3.5.0`, covering: change `author` metadata with `getAuthor`/`getAuthors`; `__proto__` assignment throws `RangeError`; bounded-chunk list insertion; `applyPatch`/`applyPatches` support for embedded rich-text blocks; patches exposing existing text objects carry marks and blocks; the large-transaction perf fix; the counter/insert ordering fix; fragment `checkpoints` excluding the head.

### 5. Licence

- `LICENSE` (repo root, 1.0 KB): MIT, `Copyright (c) 2019-2021 the Automerge contributors`. Byte-identical `LICENSE` files exist at `javascript/LICENSE` and `rust/automerge-wasm/LICENSE`.
- `rust/automerge/src/text_diff/LICENSE`: **Apache License 2.0** (10.6 KB), covering the vendored Myers diff. `rust/automerge/src/text_diff/myers.rs:1-6` states the provenance:

```
// This file was copied from the similar crate at
// https://github.com/mitsuhiko/similar/blob/2b31f65445df9093ba007ca5a5ae6a71b899d491/src/algorithms/myers.rs
// The original license is in the LICENSE file in the same directory as this file
//
// This file was modified to use a Diff trait defined in this file rather than the DiffHook trait
// defined in `similar` and to remote the deadline parameter to the `diff` function.
```

- `javascript/README.md:120-121` restates "Copyright 2017–present, the Automerge contributors. Released under the terms of the MIT license".
- Everything in the Rust workspace is declared `license = "MIT"`.

---

## Semantics

Invariants and rules provable from the artefacts above.

1. **Every input to `Automerge::load` is untrusted and must not panic.** Proven three ways: the only fuzz target calls `Automerge::load` on arbitrary bytes with the result discarded (`fuzz/fuzz_targets/load.rs:34-36`); `hexane/README.md:153-156` states `load` "fully validates: every run header, every value, UTF-8 for strings, delta running sums with overflow checks, domain checks per type. Only after that validation do the unchecked hot paths ever touch the bytes"; and the 8 committed crashers must all yield `Err` (`tests/test.rs:2210-2219`).
2. **Hexane's failure-mode policy is three-way**: precondition violation → panic; malformed untrusted bytes → `Err(PackError)`; impossible query → empty result (`rust/hexane/README.md:184-190`).
3. **Wire format is frozen.** `rust/hexane/README.md:256-262` — the byte format *is* the automerge document format; a golden-fixture failure "isn't a test failure; it's a compatibility break with every existing document."
4. **Delta columns have a hard 2⁶³ value domain.** `rust/hexane/README.md:100-108` — wire deltas are `i64` and deletion makes arbitrary neighbours adjacent, so any pair of values may need their difference encoded. Writes outside the domain panic; `load` rejects with an error; queries for unstorable values return empty.
5. **All-default columns cost 3 bytes and are elided entirely.** `Column::<bool>` of 1 000 000 `false` values saves as 3 bytes; `save_to_unless(out, sentinel)` writes nothing (`rust/hexane/README.md:226-245`).
6. **Every chunk carries `magic ‖ checksum` before its type byte.** Proven by `tests/test.rs:2071-2076` (inline, labelled) and `fuzz/fuzz_targets/load.rs:16-22` (constructed), where the checksum is `SHA-256(type‖len‖payload)[0..4]`.
7. **Bad LEB128 encodings are rejected, not tolerated.** `tests/test.rs:2226-2234` — incorrect metadata and overlong LEB are both `Err`; the canonical form is `Ok`.
8. **Mark-end-before-mark-start is a load error with a documented recovery path.** `tests/rich_text_fuzz_crash.rs:222-229` asserts the error string contains `"invalid mark operation order"`; `:232-235` asserts `Automerge::rescue` returns the value. This is a **format-level** rule, added in 0.11.0, meaning a Zig port must reject the same documents.
9. **A batch containing a duplicate actor sequence number is rejected atomically.** Changelog 0.12.0 plus `tests/test.rs:3528-3663` (four tests) and `tests/test.rs:3664` (queued orphan variant). A partial apply must not corrupt the in-memory index or the saved document.
10. **A failed merge that already applied some changes must not corrupt save/load.** `tests/test.rs:3528-3557`.
11. **A `PatchLog` may only be used with the document that produced it; otherwise `PatchLogMismatch`, never a panic.** `tests/test.rs:37-78`, all four entry points.
12. **Patches are the change-propagation contract, and the round-trip law is `hydrate → patch → hydrate == hydrate`.** This exact assertion (`apply_patches` then `assert_eq!(actual, expected)`) is the shape of at least 20 tests across `test.rs`, `block_tests.rs`, `batch_insert.rs` and `rich_text_fuzz_crash.rs`. It is the single most important invariant in the suite and the most useful conformance harness for a port.
13. **Text index units must be consistent across `length`, `get`, `marks` and `get_marks`.** `tests/text.rs:1091-1120` (`get_marks_index_counts_the_same_units_as_marks`) and `tests/text.rs:1045-1089` (`get_marks_agrees_with_marks_at_every_index`); the changelog's Unreleased entry says these previously disagreed under some encodings.
14. **A multi-unit text element is one sequence element.** `tests/test.rs:249-330` and `tests/rich_text_fuzz_crash.rs:194-219`: a string inserted as a single op has text width > 1; replacing it must remove its entire rendered width, and a mark fully inside it has zero-width start and end.
15. **Historical transactions are branch-scoped and reject edits to objects outside the branch.** Changelog 0.11.0; `tests/test.rs:155-168` (`AutomergeError::InvalidObjId`), `:172-197`, `:199-216`.
16. **Empty map keys are legal.** Changelog 0.5.12; `tests/test.rs:3062-3073`.
17. **The 64-bit object-id class of bug is handled permissively.** `tests/test.rs:2256-2268` — an opId of 2⁴² truncating to 0 in 32 bits may either fail to load or load with a distinct id; the test accepts both, and explicitly says "The file should either fail to load … or be handled correctly."
18. **Sync must not stall on unrelated orphan changes or advertise changes the sender lacks.** Changelog 0.11.0; `tests/test.rs:3722-3781` (`queued_orphan_need_does_not_block_unrelated_sync_response`).
19. **Read-only sync is one-directional and a reset must resend.** Changelog 0.9.0; `javascript/test/sync_test.ts:1138` (`read-only sync`).
20. **`AutoCommit` and `PatchLog` are `Send`.** Changelog 0.5.1; compile-time assertion at `src/autocommit.rs:1376-1383`.
21. **`src/iter/keys.rs` is entirely `#[cfg(test)]`** — `KeyIter`/`KeyOpIter` do not exist in a release build (`src/iter/keys.rs:1-71`). A port must not treat them as API.
22. **The `interop/exemplar` document is the cross-platform conformance vector**, and its exported JSON is pinned in `interop/README.md:23-40`, including `uint: 18446744073709551615` (u64 max) and `timestamp: -905182979000` (the CLI's numeric timestamp rendering).
23. **A `TextRepresentation` type does not exist and must not be reconstructed.** Removed in 0.7.0 along with six method signatures that took it.
24. **`utf8-indexing` and `utf16-indexing` are mutually exclusive in practice, enforced only by convention.** `tests/test.rs:420` compiles a test out when either is enabled; nothing else in the tree asserts exclusivity.

---

## Zig mapping notes

Per construct, in the order they appear above.

**Test harness / attribute macros.** `#[test] fn name()` → `test "name" { … }`. The Rust tests span multiple files that are separate crates; a Zig equivalent is multiple test *files* each with its own `addTest`, all wired into one `zig build test` step. Straightforward.

**`use test_log::test;` (`tests/test.rs:89`, `test_mark_patches.rs:6`, `convert_string_to_text.rs:5`).** This shadows `#[test]` with a version that installs a per-test tracing subscriber. **No clean Zig equivalent**: `std.testing` installs one global test runner; there is no per-test hook. Zig's test runner does capture and discard `log` output, so the practical port is to drop the per-test subscriber and rely on `std.log` with a global `log_level` set from the runner. Everything in the repo is driven with `RUST_LOG=error` anyway (`scripts/ci/build-test:6-10`), so per-test log capture buys nothing.

**`proptest!` (`tests/text.rs:658`, and ~10 modules in `src/`).** **No clean equivalent in stock Zig 0.16.** Shrinking, arbitrary generation, and regression-seed replay are all absent. A port must either adopt a third-party fuzzing library (e.g. `ziglyph`, which provides a `proptest`-like harness with shrinking) or hand-roll. `tests/text.rs:751-833` is unusual in that it needs *no* shrinker — `arb_scenario()` is a pure state-machine generator over an `Action` enum and any failure is already minimal-ish. That specific property test is portable as an ordinary `test` with a hand-written exhaustive-or-bounded action sequence. The `src/` ones (`author.rs:286`, `exid.rs:223`, `change.rs:417`, `columnar/**`) genuinely need a framework.

**`#[ignore = "reason"]` (`rust/hexane/tests/pending.rs`, 6 tests).** No Zig equivalent. These are documentation-of-known-bugs; a port should keep them as commented-out `test` blocks with the `ignore` reason in a comment, or behind a build option that is off by default.

**`include_bytes!` (`tests/rich_text_fuzz_crash.rs:223`, `:233`)** → `@embedFile("fixtures/broken_zero_width_mark.automerge")`, giving `*const [N:0]u8`. Clean.

**`fs::read_dir` + `fs::read` at runtime (`tests/test.rs:2211`, `:2223`, `src/automerge/current_state.rs:522`).** `@embedFile` needs a compile-time path list, so the 8 crashers and 9 fixtures must each become an explicit `const` array in the test file. `zig test` does **not** guarantee the process cwd is the package root, so the runtime-path approach is fragile. Recommend generating the list in `build.zig` with `addWriteFiles`, or just hard-coding the 17 paths in the test file — the corpus is small enough that a hand-written array is the boring choice.

**`pretty_assertions::assert_eq!` (`tests/test.rs:88`)** → `std.testing.expectEqualDeep`. Note the tests compare `hydrate::Value` trees and `Vec<Patch>`; both are deeply nested unions/enums, so a hand-written `expectEqualDeep`-style comparison for `hydrate::Value` will be needed (Zig's `expectEqualDeep` does not understand custom unions without a peer type). [INFERENCE] the ergonomics; the struct shapes are covered by the API slices.

**`maplit!` / `hydrate_map!` / `hydrate_list!` / `hydrate_text!`** (`tests/batch_insert.rs:19-20`, `:222`, etc.) → comptime literal builders: `comptime hydrateMap(.{ .a = "hello", .outter = ... })`. `hydrate_map!` is a public `automerge` macro (`automerge::{hydrate_map, hydrate_list, hydrate_text}` at `tests/batch_insert.rs:6`), so a port must decide whether to keep a macro surface. A comptime function taking an anonymous struct is closer in spirit and needs no macro machinery.

**`automerge_test` assertions (`assert_doc!`, `assert_obj!`, `list!`, `map!`, `mk_counter!`, `new_doc!`, `realize!`, …, `tests/test.rs:81-88`).** A dev-dependency crate of assertion macros. A Zig port should fold these into the test file as plain helper functions returning a runtime error union.

**`is_send::<AutoCommit>()` (`src/autocommit.rs:1376-1383`).** **No clean Zig equivalent.** Zig has no `Send`/`Sync` bound; the type system will not reject a type that captures thread-local state. The test's *intent* — "`AutoCommit` may be moved to another thread" — is enforceable in Zig only by an explicit audit that the struct contains no thread-affine pointers, or by writing the actual test: construct a doc, move it into a freshly spawned `std.Thread`, and mutate it there. That is the honest port.

**`debug_cmp` / `save_checkpoint` (`src/op_set2/columns.rs:82-99`, `src/op_set2/op_set.rs:68-81`, `src/automerge.rs:580-582`, `:1164-1166`).** `#[cfg(test)]`-only introspection used by `reproduce_clock_cache_bug` (`tests/test.rs:3258-3403`) to compare two documents column-by-column. Zig has no `cfg(test)`. Two options: expose them unconditionally and document as internal, or gate on a build option. A `pub` function Zig-idiomatically has no "internal" visibility other than the `@import` boundary, so a separate `testsupport` module imported only by the test root is the cleanest structure.

**`KeyIter` / `KeyOpIter` existing only under `#[cfg(test)]` (`src/iter/keys.rs:1-71`)** → simply do not port them outside the test tree.

**`make_rng() -> SmallRng` (`src/lib.rs:322-325`)** → a comptime-seeded PRNG. Zig's `std.Random.DefaultPrng` is a good fit; the Rust code uses `rand 0.10`'s `SmallRng` for reproducibility across runs, which a port must reproduce by pinning an algorithm, not a seed alone.

**`#[cfg(not(any(feature = "utf16-indexing", feature = "utf8-indexing")))]` (`tests/test.rs:420`)** → a build option. In Zig this becomes a comptime boolean threaded through `builtin` or a module-level constant. **The hazard**: the Rust idiom is a *per-test* gate; the Zig idiom is a *whole-build* switch. If a port makes text encoding a build option, `current_state_diff_with_block_applies_to_hydrated_value_from_fuzz_trace` disappears from every configuration instead of from two. Recommendation: make `TextEncoding` a **runtime value threaded through the document**, which is what `AutoCommit::new_with_encoding` already does, and only keep a compile-time constant for the hot width-table. Then all four encodings are testable in one binary and the gate is unnecessary.

**Cargo features → build options.** The five `automerge` features and five `hexane` features have no Cargo analogue. In `build.zig`: `b.standardTargetOptions` plus explicit `options` enum, and `const Options = struct { wasm: bool, utf8_indexing: bool, utf16_indexing: bool, slow_path_assertions: bool, deep_fuzz: bool, bijou64: bool }`. Every feature gate in the source becomes `if (opts.slow_path_assertions)` inside a `comptime` branch. `slow_path_assertions` matters for a port: the Rust default is *off* even in debug, so a naive Zig port that enables debug assertions unconditionally will be measurably slower than the reference and will trip `scripts/ci/build-test`-equivalent budgets. See `rust/CHANGELOG.md` 0.8.0.

**Workspace members → build modules.** The eight workspace crates become `b.addModule` + a `lib`/`exe` per member. Nothing needs versions. `[profile.release] lto = true, codegen-units = 1` maps to `b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall })` — Zig has no LTO knob and never splits codegen units, so this is closer to ReleaseSmall than ReleaseFast.

**`resolver = "2"`** → no analogue; Zig has one global dependency set per build. The one place it matters: `flate2` is declared with `default-features = false, features = ["zlib-rs"]` (pure-Rust DEFLATE) precisely so it works on wasm. In Zig, a DEFLATE implementation is a real choice: `std.compress.flate` is the obvious candidate but is *decoding-only*; a port needs an **inflate + deflate** pair that is byte-compatible with the fixtures. This is the highest-risk single dependency decision and the fixtures in §2 are the acceptance test.

**`rand ^0.10` declared `optional = false`** — a real, non-optional runtime dependency of the core crate (used for default actor ids and for `anonymize`'s seeded PRNG). Zig's `std.crypto.random` covers the unseeded case; the seeded case needs a ported PRNG.

**`sha2 ^0.11.0-rc.5`** — a release-candidate dependency in a library that claims MSRV pinning. `std.crypto.hash.sha2.Sha256` is available in Zig; the chunk checksum is `SHA-256(...)[0..4]` (`fuzz/fuzz_targets/load.rs:16-22`), so only the truncated-prefix use is needed.

**`unicode-segmentation 1.10.1`** — grapheme clustering. **No stdlib equivalent.** `std.unicode` provides UTF-8/UTF-16/UTF-32 iteration and `utf8Validate`, but not UAX #29 grapheme clusters. `TextEncoding::GraphemeCluster` is one of the four encodings exercised by all 15 `text_encoding.rs` scenarios and by `test.rs:399`. A port must either implement UAX #29 or drop that encoding — dropping it silently changes `length()` results for every document containing emoji, which is exactly the class of bug `test.rs:1108-1120` catches. [INFERENCE] on effort; the test surface is proven.

**`tinyvec` / `smallvec`-style `Vec` variants** → `std.ArrayList` plus explicit capacity heuristics, or a fixed-capacity inline array for the hot op columns. Not a blocker.

**`serde` derive surface.** `automerge` itself only needs `Serialize`/`Deserialize` on `Author` (`src/author.rs`, proptest at `:348-356` asserts JSON round-trip through the hex string) and on `smol_str`. The **JS binding** is where `serde` matters: `automerge-wasm` uses `serde-wasm-bindgen 0.6.5` and `serde_bytes 0.11.5` (`rust/automerge-wasm/Cargo.toml:40-42`) to marshal whole `hydrate::Value` trees across the FFI boundary. A Zig port that targets wasm must hand-roll a JS-value marshaller for `hydrate::Value`, `Patch`, `Mark`, `Span` and `Change`; there is no derive macro to lean on. If the port targets native only, `serde` can be dropped entirely — but then the JS conformance suite in §1e becomes inapplicable.

**`#[derive(Default)]`, `Clone`, `PartialEq`, `Debug`** → Zig has no derives. `PartialEq` maps to a hand-written `pub fn eql(a: *const T, b: *const T) bool`; `Debug` to `std.debug.format` impls. `Default` maps to a zero-initialising struct, which only works if the struct has no `undefined` padding — for the op-column structs this is a real constraint, not a formality.

**`smallvec`/`Cow<'a, str>` (`MapRangeItem::key` is `Cow<'a, str>` per 0.7.0)** → `[]const u8` for borrowed, `[]u8` for owned, with a `union(enum) { borrowed: []const u8, owned: []u8 }` when the API must offer both. The changelog shows this exact shape of change is API-visible, so the port should pick one and document it.

**`Option<T>` → `?T`, `Result<T, E>` → `T || E`.** Direct. Note `Result<_, PatchLogMismatch>` (0.10.0) is a new error variant that must exist in the Zig error set, and that a Rust `Err` is a *value* while a Zig error is control flow — `tests/test.rs:51-78` shows the distinction is observable to callers.

**Enums → tagged unions.** `ScalarValue`, `Prop`, `ObjType`, `PatchAction`, `Span`, `ExpandMark`, `TextEncoding`, `MessageFlag`, `Message`, `OnPartialLoad`, `VerificationMode` are all tagged unions in Zig. `ExpandMark::{Before, After, Both, None}` is literally a 2-bit field in Rust; in Zig it will be a union and the *set* is a struct-of-bools or a `packed struct(u2)`.

**`ActorId` / `Author` / `Hash` (32-byte) newtypes** → `struct { bytes: [N]u8 }` with hand-written `eql`, `cmp`, `toHex`, `parseHex`. `ActorId::random()` and `Author::from(vec![…])` come from the test code directly (`tests/test.rs:1970`, `:3462`), so the byte-level constructors must be public.

**Borrowing → slices/pointers.** `automerge`'s `ReadDoc` is a read-only view over a shared op set with interior mutability for caches (e.g. `src/op_set.rs:68-81` exposes a `&self` method that mutates debug state). The Rust code uses `Rc`/`Arc` (`marks::MarkSet` is `Arc<MarkSet>` in `tests/block_tests.rs:12`, `tests/diff_marks.rs:6`) and `Send` types. In Zig this becomes raw pointers plus explicit lifetimes-by-convention, and the "no aliasing mutable + immutable views" rule that the borrow checker enforces for free in Rust becomes a manual invariant. **This is where a Zig port will get it wrong.** The suite's panic-free shape means a borrow violation shows up as memory corruption, not a test failure.

**Procs / build.** `cbindgen` (`rust/automerge-c/build-dependencies`) generates the C header; the header is *generated at build time* and "subject to change based on the platform and the release version" (`rust/automerge-c/README.md:22-25`). A Zig port emitting a C API needs its own `translate-c` step or a hand-written header.

**MSRV 1.90 → irrelevant.** Zig 0.16 has no MSRV concept. The 1.89/1.90 constraints in `benchmark-battery/Cargo.toml:5` and everywhere else carry no port meaning; the 0.11.0 changelog's "MSRV 1.90" is a policy statement only.

**Licence.** MIT permits anything. But `rust/automerge/src/text_diff/myers.rs` is **Apache-2.0** (upstream `mitsuhiko/similar` at a pinned commit). Apache-2.0 is MIT-compatible for distribution but carries a patent grant and a NOTICE/attribution obligation. A Zig port that copies `myers.rs` must (a) keep the attribution comment, (b) ship `text_diff/LICENSE`, and (c) not silently relicense it MIT. `cargo deny`'s allow-list (`rust/deny.toml:68`) confirms the project treats this as a real constraint.

**CI matrix → `build.zig` steps.** `fmt` → `zig fmt --check`. `lint` → `cargo clippy --all-targets --all-features -D warnings` has **no Zig equivalent**; the honest replacements are `zig build test` plus (if adopted) a lint step. `docs` (`cargo doc --document-private-items` with `-D warnings`) → `zig build docs`. `cargo-deny` (advisories, bans, sources) → no analogue; dependency advisories become a `build.zig.zon` hash-update review. The macOS/Linux/Windows triple and the wasm32 build become `zig build test -Dtarget=…` steps. `flake.nix`'s `ci-*` apps map to a `build.zig` step name per job.

**`cargo test -p automerge-wasm`** runs under `wasm32-unknown-unknown` with `RUSTDOCFLAGS`-style bindings; the equivalent in Zig is `zig build test -Dtarget=wasm32-freestanding-wasi` or a `wasm-bindgen`-style shim — Zig has no built-in JS binding generator for wasm32-unknown-unknown. **If the port targets native only, the entire §1d/§1e layer (~20 JS/TS files, 13 packaging scenarios, the Deno test) drops out of scope.** That is the single biggest scope lever in this document.

---

## Risk

Ordered by how likely a Zig port is to get it wrong silently.

1. **`hexane`'s ~525 unit tests never run in CI.** `scripts/ci/build-test:5-10` runs `-p automerge`, `-p automerge-test`, `-p automerge-c`, `-p automerge-cli`, `-p automerge-wasm` — never `-p hexane`. The crate that owns the frozen wire format (per its own README) has a test suite CI does not execute, and which lives in one 193 KB file (`rust/hexane/src/tests.rs`) rather than in reviewable pieces. A port cannot inherit the confidence that CI has been checking it. **Run the whole suite locally before trusting any wire-format claim.**

2. **The on-disk fixture corpus is 1162 bytes across 9 files.** It covers LEB128 canonicality, chunk framing, chunk ordering, compression, 64-bit obj ids, and one rich-text ordering bug. It covers **nothing** about: multi-change documents, conflict resolution, the sync protocol, text with marks, deleted objects, the `author` footer (added 0.12.0), bundles, or fragments (0.11.0, experimental). [INFERENCE] the coverage gaps, from the complete file listing. The `test.rs` integration tests generate most of their documents in-process, so they are not portable as data — a Zig port must re-derive them, and every re-derivation is a place to introduce a divergence.

3. **Round-tripping patches through `hydrate` is the dominant invariant and it is easy to fake.** 20+ tests assert `hydrate(doc') == hydrate(doc).apply_patches(patches)`. A port that returns an empty patch list trivially satisfies the "nothing to apply" case and fails only where a test constructs a non-empty patch. Several tests guard against this (`tests/test.rs:2855-2896` explicitly notes "Disable patch log to make sure we are testing the diff not the patch log" at `tests/block_tests.rs:732`). Any port must keep those two patch sources distinct.

4. **The 0.7.0 representation collapse is irreversible in Rust and easy to re-invent in Zig.** `TextRepresentation` is gone; six signatures lost it. A port reading an older Automerge design document, or the JS layer's own `TextRepresentation`-shaped code, will produce a `TextEncoding` parameter in the wrong place. The changelog explicitly calls 0.7.0's list "exhaustive" — treat it as the contract, and check the port's surface against it item by item.

5. **Author identity is stored in "the extra bytes of an actor's first change"** (0.12.0) and `Change::author` may return `None` for later changes by the same actor. This is a fragile invariant: a port that writes the author footer on every change will produce documents the reference loader may reject (`DuplicateAuthor` is a hard error). `tests/test.rs:3461-3527` (`authorship`) is the only test.

6. **`Value::to_*` are deprecated but not removed; `Value::as_*` are the replacements.** A port that exposes only one set is fine; a port that exposes both must match behaviour exactly, since the changelog says "Their behavior is unchanged."

7. **Text index units are the highest-frequency source of a silently wrong port.** Four encodings, `length`/`get`/`marks`/`get_marks`/cursor positions all measured in the *document's* encoding, and the Unreleased changelog entry says these *used to* disagree. `tests/text_encoding.rs` covers 15 scenarios × 4 encodings; `tests/text.rs:1045-1120` cross-checks units; `tests/test.rs:4145-4179` checks that every change-chunk kind preserves the encoding on incremental load. Any of these three test groups is a direct port target and should be ported *first*.

8. **Borrow-checker invariants do not survive the translation.** The library hands out `Value<'a>`, `Cow<'a, str>`, `Mark` (no lifetime since 0.7.0), and iterators over shared op data, while mutating internal caches through `&self`. In Zig these become raw-pointer aliases with no compile-time protection. The failure mode is heap corruption, not a test failure, and the test suite was written against a compiler that guaranteed the property. Mitigation: port the aliasing-sensitive modules (`op_set2`, `storage/parse`, `iter`) with explicit ownership comments and run the suite under a debug allocator; consider `-fsanitize` equivalents.

9. **`getrandom` 0.4 + the Node-18 WebCrypto polyfill** is a live, cross-project contract documented only in `javascript/HACKING.md:192-219` and enforced by a dedicated CI job plus a conditional script that silently `exit 0`s when `fnm` is unavailable (`scripts/ci/node_18_packaging_test:19-22`). Any port that keeps the JS layer inherits this maintenance burden; any port that drops it loses the JS conformance suite for free.

10. **DEFLATE is not solved by the standard library.** `flate2` with `zlib-rs` is a deliberate, recent (0.11.0) choice, and `tests/test.rs:2046-2069` (`test_compressed_doc_cols`) asserts **per-column** deflate bit behaviour, and `:2031-2045` (`test_compressed_changes`) depends on `DEFLATE_MIN_SIZE = 250`. `std.compress.flate` decodes but does not encode. A port must supply a deflate whose output the reference `automerge` can still read, or the three `two_change_chunks*` fixtures and the `save()` output stop being byte-compatible. The compression *level* is not specified anywhere in the repo, so bit-identical `save()` output is **not** a stated requirement — only round-trip compatibility is. [INFERENCE] from the absence of any golden `save()` byte assertion.

11. **Unicode grapheme clustering has no stdlib path**, yet `TextEncoding::GraphemeCluster` is one of the four encodings under test and is used by `tests/test.rs:399`. Dropping it changes `length()` for every emoji-bearing document. Implementing UAX #29 correctly is a project in itself.

12. **The changelog lags the code in two places**: `automerge` is at Cargo version `0.12.0` with an unreleased section on top, and `hexane` is at `1.0.0-alpha.5` with changelog entries only through `alpha.2`. A port that treats the changelog as exhaustive will miss the alpha.3–alpha.5 changes to the storage engine — precisely the component that owns the wire format.

13. **`cargo deny` bans all git dependencies** (`rust/deny.toml:185`, `allow-git = []`) and enforces `multiple-versions = "deny"`. A Zig port's `build.zig.zon` has no equivalent policy mechanism; the constraint has to be enforced by review.

14. **`is_send` has no Zig analogue and the constraint is real.** `AutoCommit` and `PatchLog` are `Send` (0.5.1) and the JS/wasm layer moves documents across boundaries. A Zig type with hidden thread-local state would pass every test and fail on a real multi-threaded consumer.

15. **Runtime-path fixture loading will break under `zig test`.** `tests/test.rs:2211` and `:2223` and `src/automerge/current_state.rs:522` all use `fs::read("./tests/fixtures/…")` relative to the process cwd. Under `zig build test` the cwd is the build root, not the package root. This is a known, mechanical breakage with a mechanical fix (`@embedFile`), but it is the *first* thing that will fail and, if the fixtures are simply deleted to make the build green, the wire-format regression coverage is gone with no signal.

16. **Nothing in this repo is a differential test against another implementation.** The only cross-implementation artefact is `interop/exemplar` (406 B) plus its pinned export JSON. There is no second-implementation oracle, so a Zig port can only be validated against itself and against 1.1 KB of fixtures. Anything beyond that requires an external conformance corpus.
