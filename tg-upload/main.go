package main

import (
	"context"
	"fmt"
	"os"
)

func main() {
	if err := run(context.Background(), os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "tg-upload: %v\n", err)
		os.Exit(1)
	}
}

// run dispatches subcommands. With no recognized subcommand it uploads (the
// historical behaviour: `tg-upload --file … --chat …`).
func run(ctx context.Context, args []string) error {
	if len(args) > 0 && args[0] == "download" {
		return runDownload(ctx, args[1:])
	}
	return runUpload(ctx, args)
}
