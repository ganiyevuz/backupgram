package main

import (
	"context"
	"fmt"
	"os"

	"github.com/gotd/td/tg"
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

// editCaptionAfterSend is implemented in caption.go (a later task). Temporary stub.
func editCaptionAfterSend(ctx context.Context, api *tg.Client, peer tg.InputPeerClass, upd tg.UpdatesClass, caption string) {
}
