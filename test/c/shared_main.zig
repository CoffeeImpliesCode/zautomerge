//! C consumer entry point; all assertions live in shared_corpus.c.
extern fn shared_corpus_main() callconv(.c) c_int;

pub fn main() u8 {
    return if (shared_corpus_main() == 0) 0 else 1;
}
