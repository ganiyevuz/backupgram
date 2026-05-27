package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/gotd/td/telegram"
	"github.com/gotd/td/telegram/message"
	"github.com/gotd/td/telegram/message/styling"
	"github.com/gotd/td/telegram/uploader"
	"github.com/gotd/td/tg"
)

func main() {
	if err := run(context.Background()); err != nil {
		fmt.Fprintf(os.Stderr, "tg-upload: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context) error {
	file := flag.String("file", "", "path to the file to upload (required)")
	chat := flag.String("chat", "", "target chat id (required)")
	thread := flag.Int("thread", 0, "message thread / forum topic id (0 = none)")
	caption := flag.String("caption", "", "document caption")
	flag.Parse()

	if *file == "" || *chat == "" {
		return errors.New("--file and --chat are required")
	}

	rawAPIID := os.Getenv("TELEGRAM_API_ID")
	if rawAPIID == "" {
		return errors.New("TELEGRAM_API_ID must be set")
	}
	apiID, err := strconv.Atoi(rawAPIID)
	if err != nil {
		return fmt.Errorf("invalid TELEGRAM_API_ID %q: %w", rawAPIID, err)
	}
	apiHash := os.Getenv("TELEGRAM_API_HASH")
	botToken := os.Getenv("TELEGRAM_BOT_TOKEN")
	if apiHash == "" || botToken == "" {
		return errors.New("TELEGRAM_API_HASH and TELEGRAM_BOT_TOKEN must be set")
	}

	peer, err := ParseChatID(*chat)
	if err != nil {
		return err
	}

	f, err := os.Open(*file)
	if err != nil {
		return fmt.Errorf("open file: %w", err)
	}
	defer f.Close()
	stat, err := f.Stat()
	if err != nil {
		return fmt.Errorf("stat file: %w", err)
	}

	// Bound the whole operation so a hung upload cannot wedge the backup cycle.
	ctx, cancel := context.WithTimeout(ctx, 60*time.Minute)
	defer cancel()

	client := telegram.NewClient(apiID, apiHash, telegram.Options{})
	return client.Run(ctx, func(ctx context.Context) error {
		if _, err := client.Auth().Bot(ctx, botToken); err != nil {
			return fmt.Errorf("bot auth: %w", err)
		}

		api := tg.NewClient(client)
		baseName := filepath.Base(*file)

		inputFile, err := uploader.NewUploader(api).
			WithThreads(4).
			WithPartSize(512 * 1024).
			WithProgress(&progressLogger{}).
			Upload(ctx, uploader.NewUpload(baseName, f, stat.Size()))
		if err != nil {
			return fmt.Errorf("upload: %w", err)
		}

		var docOpts []message.StyledTextOption
		if *caption != "" {
			docOpts = append(docOpts, styling.Plain(*caption))
		}
		doc := message.UploadedDocument(inputFile, docOpts...).
			Filename(baseName).
			ForceFile(true)

		// gotd's RequestBuilder.To returns a *RequestBuilder; CloneBuilder is the
		// intended way to obtain the *Builder that .Media is called on. The thread
		// branch gets it via Reply (routing into a forum topic); both keep the peer.
		requestBuilder := message.NewSender(api).To(peer)
		var sender *message.Builder
		if *thread != 0 {
			sender = requestBuilder.Reply(*thread)
		} else {
			sender = requestBuilder.CloneBuilder()
		}
		if _, err := sender.Media(ctx, doc); err != nil {
			return fmt.Errorf("send: %w", err)
		}
		return nil
	})
}
