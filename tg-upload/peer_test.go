package main

import (
	"reflect"
	"testing"

	"github.com/gotd/td/tg"
)

func TestParseChatID(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want tg.InputPeerClass
	}{
		{"user", "123456789", &tg.InputPeerUser{UserID: 123456789}},
		{"basic group", "-123456789", &tg.InputPeerChat{ChatID: 123456789}},
		{"supergroup/channel", "-1001234567890", &tg.InputPeerChannel{ChannelID: 1234567890}},
		{"leading/trailing space", "  42 ", &tg.InputPeerUser{UserID: 42}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ParseChatID(tt.in)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("ParseChatID(%q) = %#v, want %#v", tt.in, got, tt.want)
			}
		})
	}
}

func TestParseChatIDInvalid(t *testing.T) {
	if _, err := ParseChatID("notanumber"); err == nil {
		t.Fatal("expected error for non-numeric chat id")
	}
}
