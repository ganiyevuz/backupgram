package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/gotd/td/telegram"
	"github.com/gotd/td/telegram/downloader"
	"github.com/gotd/td/tg"
)

// runDownload fetches a single message by id from a chat and downloads its
// document to --out, printing the resulting local path to stdout.
func runDownload(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("tg-upload download", flag.ContinueOnError)
	chat := fs.String("chat", "", "source chat id (required)")
	msgID := fs.Int("message", 0, "message id of the backup (required)")
	out := fs.String("out", ".", "output directory")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *chat == "" || *msgID == 0 {
		return errors.New("download: --chat and --message are required")
	}

	apiID, apiHash, botToken, err := credsFromEnv()
	if err != nil {
		return err
	}
	peer, err := ParseChatID(*chat)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(ctx, 60*time.Minute)
	defer cancel()

	client := telegram.NewClient(apiID, apiHash, telegram.Options{})
	return client.Run(ctx, func(ctx context.Context) error {
		if _, err := client.Auth().Bot(ctx, botToken); err != nil {
			return fmt.Errorf("bot auth: %w", err)
		}
		api := tg.NewClient(client)

		msgs, err := fetchMessage(ctx, api, peer, *msgID)
		if err != nil {
			return err
		}
		doc, name, err := documentFromMessages(msgs, *msgID)
		if err != nil {
			return fmt.Errorf("no backup file in message %d of chat %s: %w", *msgID, *chat, err)
		}

		dest := filepath.Join(*out, name)
		fmt.Fprintf(os.Stderr, "tg-upload: ⬇️ downloading %s (message %d)...\n", name, *msgID)
		if _, err := downloader.NewDownloader().
			WithPartSize(512*1024).
			Download(api, doc.AsInputDocumentFileLocation()).
			WithThreads(4).
			ToPath(ctx, dest); err != nil {
			return fmt.Errorf("download: %w", err)
		}
		// stdout = the path, for the calling shell to capture.
		fmt.Println(dest)
		return nil
	})
}

// fetchMessage retrieves a single message by id, choosing the channel or
// plain getMessages call based on the peer type.
func fetchMessage(ctx context.Context, api *tg.Client, peer tg.InputPeerClass, id int) (tg.MessagesMessagesClass, error) {
	ids := []tg.InputMessageClass{&tg.InputMessageID{ID: id}}
	if ch, ok := peer.(*tg.InputPeerChannel); ok {
		return api.ChannelsGetMessages(ctx, &tg.ChannelsGetMessagesRequest{
			Channel: &tg.InputChannel{ChannelID: ch.ChannelID, AccessHash: ch.AccessHash},
			ID:      ids,
		})
	}
	return api.MessagesGetMessages(ctx, ids)
}
