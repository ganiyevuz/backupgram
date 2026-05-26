package main

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/gotd/td/tg"
)

// ParseChatID converts a Bot-API-style numeric chat id into an MTProto InputPeer.
//
// Conventions (matching the Telegram Bot API):
//   - id >= 0               → user/bot           → InputPeerUser
//   - id <= -1000000000000  → supergroup/channel → InputPeerChannel (strip the -100… prefix)
//   - otherwise (id < 0)    → basic group        → InputPeerChat
//
// AccessHash is left at 0: the Telegram server accepts access_hash=0 for bots
// sending to peers they belong to (groups, channels, and users who started them).
func ParseChatID(raw string) (tg.InputPeerClass, error) {
	id, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil {
		return nil, fmt.Errorf("invalid chat id %q: %w", raw, err)
	}
	switch {
	case id >= 0:
		return &tg.InputPeerUser{UserID: id}, nil
	// `<=` is safe: real supergroup/channel ids are always < -1000000000000,
	// so the exact boundary (which would yield ChannelID 0) never occurs.
	case id <= -1000000000000:
		return &tg.InputPeerChannel{ChannelID: -id - 1000000000000}, nil
	default:
		return &tg.InputPeerChat{ChatID: -id}, nil
	}
}
