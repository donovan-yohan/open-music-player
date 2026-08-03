package stems

import (
	"strings"
	"testing"
)

func TestChannelSetsMatchTheWireContract(t *testing.T) {
	cases := []struct {
		channelSet       string
		channels         []string
		stemModelVersion string
	}{
		{ChannelSetStems4Demucs, []string{"vocals", "drums", "bass", "other"}, StemModelVersionStems4},
		{ChannelSetStems5Hybrid, []string{"vocals", "melody", "bass", "kick", "perc"}, StemModelVersionStems5},
	}
	for _, testCase := range cases {
		t.Run(testCase.channelSet, func(t *testing.T) {
			channels, ok := Channels(testCase.channelSet)
			if !ok {
				t.Fatalf("channel set %q is not known", testCase.channelSet)
			}
			if len(channels) != len(testCase.channels) {
				t.Fatalf("channels = %v, want %v", channels, testCase.channels)
			}
			for index, want := range testCase.channels {
				if channels[index] != want {
					t.Fatalf("channels = %v, want %v", channels, testCase.channels)
				}
			}
			version, ok := StemModelVersionFor(testCase.channelSet)
			if !ok || version != testCase.stemModelVersion {
				t.Fatalf("stem model version = %q (ok=%v), want %q", version, ok, testCase.stemModelVersion)
			}
		})
	}
}

func TestChannelsReturnsACopy(t *testing.T) {
	first, ok := Channels(ChannelSetStems5Hybrid)
	if !ok {
		t.Fatal("channel set not known")
	}
	first[0] = "mutated"
	second, _ := Channels(ChannelSetStems5Hybrid)
	if second[0] != "vocals" {
		t.Fatalf("registry mutated through returned slice: %v", second)
	}
}

func TestHihatIsRetiredAndPercIsCanonical(t *testing.T) {
	channels, _ := Channels(ChannelSetStems5Hybrid)
	for _, channel := range channels {
		if channel == "hihat" {
			t.Fatal("retired channel name \"hihat\" is still on the wire; \"perc\" is canonical")
		}
	}
	if !containsChannel(channels, "perc") {
		t.Fatalf("channels = %v, want the canonical \"perc\" channel", channels)
	}
}

func TestMelodyAliasesTheDemucsOtherObject(t *testing.T) {
	// stems5 references the base objects rather than duplicating them, so the DJ
	// name must resolve to the demucs object it points at.
	if got := BaseObjectChannel("melody"); got != "other" {
		t.Fatalf("BaseObjectChannel(\"melody\") = %q, want \"other\"", got)
	}
	for _, channel := range []string{"vocals", "bass", "kick", "perc", "drums"} {
		if got := BaseObjectChannel(channel); got != channel {
			t.Fatalf("BaseObjectChannel(%q) = %q, want identity", channel, got)
		}
	}
}

func TestUnknownChannelSetsAreRejectedRatherThanDefaulted(t *testing.T) {
	for _, channelSet := range []string{"", "stems5-hybrid", "stems6-hybrid-v1", "bands3-v1"} {
		if IsKnownChannelSet(channelSet) {
			t.Fatalf("channel set %q reported as known", channelSet)
		}
		if _, ok := StemModelVersionFor(channelSet); ok {
			t.Fatalf("stem model version resolved for unknown channel set %q", channelSet)
		}
	}
	if !IsKnownChannelSet(DefaultChannelSet) {
		t.Fatalf("default channel set %q is not known", DefaultChannelSet)
	}
}

func TestStems5ModelVersionRecordsTheCrossover(t *testing.T) {
	// A crossover change must invalidate artifacts, so it has to be part of the
	// model identity rather than hidden in provenance alone.
	if !strings.HasPrefix(StemModelVersionStems5, StemModelVersionStems4) {
		t.Fatalf("stems5 model version %q does not extend the stems4 base %q", StemModelVersionStems5, StemModelVersionStems4)
	}
	if StemModelVersionStems5 == StemModelVersionStems4 {
		t.Fatal("stems5 and stems4 share a model version; a crossover change would not invalidate artifacts")
	}
	if !strings.Contains(DerivationCrossover, "lr4-180") {
		t.Fatalf("crossover derivation tag = %q, want the LR4-180Hz identity", DerivationCrossover)
	}
}

func TestJobIDMatchesTheTrackStemsIdentity(t *testing.T) {
	got := JobID(123, ChannelSetStems5Hybrid, StemModelVersionStems5)
	want := "123:" + ChannelSetStems5Hybrid + ":" + StemModelVersionStems5
	if got != want {
		t.Fatalf("JobID = %q, want %q", got, want)
	}
	if JobID(123, ChannelSetStems4Demucs, StemModelVersionStems4) == got {
		t.Fatal("different channel sets share a job ID")
	}
}

func containsChannel(channels []string, want string) bool {
	for _, channel := range channels {
		if channel == want {
			return true
		}
	}
	return false
}
