package workbench

import (
	"context"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"

	"golang.org/x/crypto/ssh"
)

func TestMacOSDNSFlushUsesProvisioningSSH(t *testing.T) {
	for _, code := range []uint32{0, 1} {
		t.Run(fmt.Sprint(code), func(t *testing.T) {
			var calls atomic.Int32
			g := newMacWorkspaceGuest(t, func(ch ssh.Channel, command string) (uint32, bool) {
				calls.Add(1)
				for _, required := range []string{"exec /usr/bin/sudo -S -p ''", "/usr/bin/env -i PATH=/usr/bin:/bin /bin/sh -ec", "/usr/bin/dscacheutil -flushcache\n/usr/bin/killall -HUP mDNSResponder", `< "$HOME/password"`} {
					if !strings.Contains(command, required) {
						t.Errorf("missing fixed provisioning operation %q", required)
					}
				}
				fmt.Fprint(ch.Stderr(), "synthetic-private-output-must-not-escape")
				return code, true
			})
			err := g.s.flushMacOSDNSAfterGrant(t.Context())
			if (err != nil) != (code != 0) || calls.Load() != 1 {
				t.Fatalf("calls=%d error=%v", calls.Load(), err)
			}
			if err != nil && strings.Contains(err.Error(), "synthetic-private-output") {
				t.Fatal("remote stderr escaped")
			}
		})
	}
}

func TestMacOSDNSFlushCancellationAndNonMacOS(t *testing.T) {
	s := testServer(t)
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	// No profile, SSH configuration, or subprocess is needed for other guests.
	if err := s.flushMacOSDNSAfterGrant(ctx); err != nil {
		t.Fatal(err)
	}
	var calls atomic.Int32
	g := newMacWorkspaceGuest(t, func(_ ssh.Channel, _ string) (uint32, bool) { calls.Add(1); return 0, true })
	if err := g.s.flushMacOSDNSAfterGrant(ctx); err == nil {
		t.Fatal("cancelled flush succeeded")
	}
	if calls.Load() != 0 {
		t.Fatal("cancelled flush reached guest")
	}
}
