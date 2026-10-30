package main

import (
	"net/netip"
	"slices"
	"testing"
)

func TestEgressBlockRanges(t *testing.T) {
	cfg := defaultConfig()
	cfg.Network.Pool = "172.30.0.0/16"
	cfg.Network.DNS = []string{"1.1.1.1", "10.0.0.53"}
	cfg.Network.Egress.Block = []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "10.42.0.0/16"}
	cfg.Network.Egress.Allow = []string{"192.168.10.0/24"}
	host := []netip.Addr{netip.MustParseAddr("192.168.1.20"), netip.MustParseAddr("203.0.113.7"),
		netip.MustParseAddr("127.0.0.1"), netip.MustParseAddr("fe80::1")}

	got, err := egressBlockRanges(cfg, host)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"10.0.0.0-10.0.0.52", "10.0.0.54-10.255.255.255", // the private DNS server stays reachable
		"172.16.0.0-172.31.255.255", // includes the tenant pool
		"192.168.0.0-192.168.9.255", "192.168.11.0-192.168.255.255",
		"203.0.113.7", // the node's public address
	}
	if !slices.Equal(got, want) {
		t.Errorf("got  %v\nwant %v", got, want)
	}

	cfg.Network.Egress.Block = []string{"fd00::/8"}
	if _, err := egressBlockRanges(cfg, nil); err == nil {
		t.Error("IPv6 block entries must be rejected")
	}
}

func TestNormalizeEdges(t *testing.T) {
	all := []ipRange{{0, 10}, {11, ^uint32(0)}, {5, 6}}
	if got := normalize(all); len(got) != 1 || got[0] != (ipRange{0, ^uint32(0)}) {
		t.Errorf("got %v", got)
	}
	if got := subtract([]ipRange{{0, ^uint32(0)}}, []ipRange{{0, 0}, {^uint32(0), ^uint32(0)}}); len(got) != 1 || got[0] != (ipRange{1, ^uint32(0) - 1}) {
		t.Errorf("got %v", got)
	}
}
