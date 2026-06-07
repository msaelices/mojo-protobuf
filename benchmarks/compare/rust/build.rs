fn main() {
    prost_build::compile_protos(&["../bench.proto"], &[".."]).unwrap();
}
