package main

import "testing"

import "github.com/gotd/td/tg"

func TestMessageIDFromUpdates(t *testing.T) {
	// UpdateMessageID carries the sent id.
	u1 := &tg.Updates{Updates: []tg.UpdateClass{&tg.UpdateMessageID{ID: 4521}}}
	if id, ok := messageIDFromUpdates(u1); !ok || id != 4521 {
		t.Errorf("UpdateMessageID: got (%d,%v), want (4521,true)", id, ok)
	}

	// UpdateNewChannelMessage carries a *tg.Message with the id.
	u2 := &tg.Updates{Updates: []tg.UpdateClass{
		&tg.UpdateNewChannelMessage{Message: &tg.Message{ID: 99}},
	}}
	if id, ok := messageIDFromUpdates(u2); !ok || id != 99 {
		t.Errorf("UpdateNewChannelMessage: got (%d,%v), want (99,true)", id, ok)
	}

	// No id-bearing update.
	u3 := &tg.Updates{Updates: []tg.UpdateClass{&tg.UpdateUserTyping{}}}
	if _, ok := messageIDFromUpdates(u3); ok {
		t.Error("expected ok=false when no message id present")
	}
}

func TestDocumentFromMessages(t *testing.T) {
	doc := &tg.Document{ID: 7}
	doc.Attributes = []tg.DocumentAttributeClass{
		&tg.DocumentAttributeFilename{FileName: "mydb-20260529.sql.gz.gpg"},
	}
	msgs := &tg.MessagesMessages{Messages: []tg.MessageClass{
		&tg.Message{ID: 4521, Media: &tg.MessageMediaDocument{Document: doc}},
	}}

	gotDoc, name, err := documentFromMessages(msgs, 4521)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotDoc.ID != 7 || name != "mydb-20260529.sql.gz.gpg" {
		t.Errorf("got (id=%d, name=%q), want (7, mydb-20260529.sql.gz.gpg)", gotDoc.ID, name)
	}
}

func TestDocumentFromMessagesErrors(t *testing.T) {
	// Message present but no document (e.g. a text alert).
	textOnly := &tg.MessagesMessages{Messages: []tg.MessageClass{&tg.Message{ID: 1}}}
	if _, _, err := documentFromMessages(textOnly, 1); err == nil {
		t.Error("expected error for message without a document")
	}
	// Requested id not present.
	if _, _, err := documentFromMessages(textOnly, 999); err == nil {
		t.Error("expected error when message id not found")
	}
	// Empty / messagesNotModified-like.
	if _, _, err := documentFromMessages(&tg.MessagesMessages{}, 1); err == nil {
		t.Error("expected error for empty message list")
	}
}

func TestRestoreIDLine(t *testing.T) {
	if got := restoreIDLine(4521); got != "🔖 Restore ID: 4521" {
		t.Errorf("restoreIDLine(4521) = %q", got)
	}
}
