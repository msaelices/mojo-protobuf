use prost::Message;
include!(concat!(env!("OUT_DIR"), "/cmp.rs"));

fn time_it<F: Fn()>(f: F, iters: usize) -> f64 {
    for _ in 0..iters / 20 { f(); }
    let mut best = f64::INFINITY;
    for _ in 0..5 {
        let t0 = std::time::Instant::now();
        for _ in 0..iters { f(); }
        let ns = t0.elapsed().as_nanos() as f64 / iters as f64;
        if ns < best { best = ns; }
    }
    best
}

fn main() {
    let data = std::fs::read("../packed.bin").unwrap();
    let iters = 50000usize;
    let dec = time_it(|| {
        let m = Packed::decode(&data[..]).unwrap();
        assert_eq!(m.values.len(), 2000);
    }, iters);
    let msg = Packed::decode(&data[..]).unwrap();
    let enc = time_it(|| {
        let b = msg.encode_to_vec();
        assert!(!b.is_empty());
    }, iters);
    println!("rust(prost)   decode {:8.0} ns   encode {:8.0} ns", dec, enc);
}
