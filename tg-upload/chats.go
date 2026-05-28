package main

import (
	"fmt"
	"strings"

	"github.com/gotd/td/tg"
)

// chatTarget pairs a configured chat id (as written) with its resolved peer.
type chatTarget struct {
	raw  string
	peer tg.InputPeerClass
}

// splitChats parses a comma-separated list of chat ids into resolved peers.
// Whitespace around each id is ignored; empty input, an empty element, or any
// malformed id is an error.
func splitChats(raw string) ([]chatTarget, error) {
	parts := strings.Split(raw, ",")
	targets := make([]chatTarget, 0, len(parts))
	for _, part := range parts {
		id := strings.TrimSpace(part)
		if id == "" {
			return nil, fmt.Errorf("empty chat id in %q", raw)
		}
		peer, err := ParseChatID(id)
		if err != nil {
			return nil, err
		}
		targets = append(targets, chatTarget{raw: id, peer: peer})
	}
	return targets, nil
}
