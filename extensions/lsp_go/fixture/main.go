package main

import "example.com/fixture/util"

func main() {
	println(util.Greet("world"), util.Greet("again"))
	println(util.Greet("once more"))
}
