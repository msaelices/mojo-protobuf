fn main() {
    // Map google.protobuf.Timestamp (used by RtpStats) to the prost-types impl
    // rather than generating it.
    let mut config = prost_build::Config::new();
    config.extern_path(".google.protobuf.Timestamp", "::prost_types::Timestamp");
    config.compile_protos(&["../bench.proto"], &[".."]).unwrap();
}
