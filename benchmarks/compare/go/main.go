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

func main() {
	data, _ := os.ReadFile("../packed.bin")
	iters := 50000
	dec := timeIt(func() {
		var m pb.Packed
		if err := proto.Unmarshal(data, &m); err != nil {
			panic(err)
		}
		if len(m.Values) != 2000 {
			panic("bad")
		}
	}, iters)
	var msg pb.Packed
	proto.Unmarshal(data, &msg)
	enc := timeIt(func() {
		b, _ := proto.Marshal(&msg)
		if len(b) == 0 {
			panic("bad")
		}
	}, iters)
	fmt.Printf("go            decode %8.0f ns   encode %8.0f ns\n", dec, enc)
}
