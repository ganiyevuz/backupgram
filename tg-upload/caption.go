package main

import (
	"context"
	"fmt"
	"os"

	"github.com/gotd/td/tg"
)

// restoreIDLine is the caption suffix that records a message's own id so it can
// later be passed to `restore --from-telegram`.
func restoreIDLine(id int) string {
	return fmt.Sprintf("🔖 Restore ID: %d", id)
}

// editCaptionAfterSend appends the restore-id line to the just-sent message's
// caption. Failure is non-fatal: the backup is already delivered, so any error
// is logged and swallowed.
func editCaptionAfterSend(ctx context.Context, api *tg.Client, peer tg.InputPeerClass, upd tg.UpdatesClass, caption string) {
	id, ok := messageIDFromUpdates(upd)
	if !ok {
		fmt.Fprintln(os.Stderr, "tg-upload: ⚠️ could not determine sent message id; restore id not embedded")
		return
	}
	newCaption := restoreIDLine(id)
	if caption != "" {
		newCaption = caption + "\n" + newCaption
	}
	if _, err := api.MessagesEditMessage(ctx, &tg.MessagesEditMessageRequest{
		Peer:    peer,
		ID:      id,
		Message: newCaption,
	}); err != nil {
		fmt.Fprintf(os.Stderr, "tg-upload: ⚠️ failed to embed restore id %d: %v\n", id, err)
		return
	}
	fmt.Fprintf(os.Stderr, "tg-upload: 🔖 restore id %d embedded in caption\n", id)
}
