//! How many cases the randomized unit tests run. A local `zig build test`
//! runs a tenth of each full count so it stays fast. Pass `-Dfuzz=100`
//! to run them all.

const percent = @import("build_options").fuzz_percent;

pub fn runs(full: usize) usize {
    return @max(1, full * percent / 100);
}
