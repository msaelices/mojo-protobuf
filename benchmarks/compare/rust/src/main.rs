use prost::Message;
include!(concat!(env!("OUT_DIR"), "/cmp.rs"));

fn time_it<F: Fn()>(f: F, iters: usize) -> f64 {
    for _ in 0..iters / 20 {
        f();
    }
    let mut best = f64::INFINITY;
    for _ in 0..5 {
        let t0 = std::time::Instant::now();
        for _ in 0..iters {
            f();
        }
        let ns = t0.elapsed().as_nanos() as f64 / iters as f64;
        if ns < best {
            best = ns;
        }
    }
    best
}

fn run<T: Message + Default>(label: &str, data: &[u8]) {
    let iters = 50_000usize;
    let dec = time_it(
        || {
            let m = T::decode(data).unwrap();
            std::hint::black_box(&m);
        },
        iters,
    );
    let msg = T::decode(data).unwrap();
    let enc = time_it(
        || {
            let b = msg.encode_to_vec();
            assert!(!b.is_empty());
        },
        iters,
    );
    println!(
        "rust(prost)   {:7} decode {:8.0}   encode {:8.0}",
        label, dec, enc
    );
}

fn main() {
    let packed = std::fs::read("../packed.bin").unwrap();
    let person = std::fs::read("../person.bin").unwrap();
    let participant = std::fs::read("../participant.bin").unwrap();
    run::<Packed>("packed", &packed);
    run::<Person>("person", &person);
    run::<ParticipantInfo>("participant", &participant);
}
