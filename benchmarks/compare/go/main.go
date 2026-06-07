package main

import (
	"fmt"
	"os"
	"time"

	"google.golang.org/protobuf/proto"

	"cmpbench/pb"
)

func timeIt(fn func(), iters int) float64 {
	for i := 0; i < iters/20; i++ {
		fn()
	}
	best := 1e18
	for r := 0; r < 5; r++ {
		t0 := time.Now()
		for i := 0; i < iters; i++ {
			fn()
		}
		ns := float64(time.Since(t0).Nanoseconds()) / float64(iters)
		if ns < best {
			best = ns
		}
	}
	return best
}

func run(label string, data []byte, fresh func([]byte) (proto.Message, error)) {
	iters := 50000
	dec := timeIt(func() {
		if _, err := fresh(data); err != nil {
			panic(err)
		}
	}, iters)
	msg, _ := fresh(data)
	enc := timeIt(func() {
		b, _ := proto.Marshal(msg)
		if len(b) == 0 {
			panic("bad")
		}
	}, iters)
	fmt.Printf("go(protobuf-go) %-7s decode %8.0f   encode %8.0f\n", label, dec, enc)
}

func main() {
	packed, _ := os.ReadFile("../packed.bin")
	person, _ := os.ReadFile("../person.bin")
	run("packed", packed, func(d []byte) (proto.Message, error) {
		m := &pb.Packed{}
		return m, proto.Unmarshal(d, m)
	})
	run("person", person, func(d []byte) (proto.Message, error) {
		m := &pb.Person{}
		return m, proto.Unmarshal(d, m)
	})
	participant, _ := os.ReadFile("../participant.bin")
	run("participant", participant, func(d []byte) (proto.Message, error) {
		m := &pb.ParticipantInfo{}
		return m, proto.Unmarshal(d, m)
	})
}
