package ui

import "github.com/charmbracelet/lipgloss"

// Adaptive styling: every color carries a light and a dark variant so
// the transcript reads on either background.
var (
	styleStatusBar = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#FAFAFA", Dark: "#1A1A1A"}).
			Background(lipgloss.AdaptiveColor{Light: "#5A56E0", Dark: "#7D79F6"}).
			Padding(0, 1)

	styleStatusNote = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#8A6D00", Dark: "#E5C07B"})

	styleTabActive = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.AdaptiveColor{Light: "#5A56E0", Dark: "#7D79F6"}).
			Padding(0, 1).
			Border(lipgloss.NormalBorder(), false, false, true, false).
			BorderForeground(lipgloss.AdaptiveColor{Light: "#5A56E0", Dark: "#7D79F6"})

	styleTab = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#666666", Dark: "#999999"}).
			Padding(0, 1)

	styleTabLive = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#B05900", Dark: "#E5A560"}).
			Padding(0, 1)

	styleUser = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.AdaptiveColor{Light: "#0B7261", Dark: "#5EDDC5"})

	styleAssistantTag = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.AdaptiveColor{Light: "#5A56E0", Dark: "#7D79F6"})

	styleThinking = lipgloss.NewStyle().
			Italic(true).
			Foreground(lipgloss.AdaptiveColor{Light: "#8A8A8A", Dark: "#6C6C6C"})

	styleToolCall = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#B05900", Dark: "#E5A560"}).
			Border(lipgloss.RoundedBorder(), false, false, false, true).
			BorderForeground(lipgloss.AdaptiveColor{Light: "#B05900", Dark: "#E5A560"}).
			PaddingLeft(1)

	styleToolResult = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#4A4A4A", Dark: "#B8B8B8"}).
			Border(lipgloss.RoundedBorder(), false, false, false, true).
			BorderForeground(lipgloss.AdaptiveColor{Light: "#AAAAAA", Dark: "#555555"}).
			PaddingLeft(1)

	styleExitOK = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.AdaptiveColor{Light: "#1A7F37", Dark: "#57D993"})

	styleExitBad = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.AdaptiveColor{Light: "#C0273B", Dark: "#F27E8B"})

	styleError = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#C0273B", Dark: "#F27E8B"})

	styleDim = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#999999", Dark: "#666666"})

	styleCompaction = lipgloss.NewStyle().
			Italic(true).
			Foreground(lipgloss.AdaptiveColor{Light: "#7A5EA8", Dark: "#B79CE4"})

	styleOverlay = lipgloss.NewStyle().
			Border(lipgloss.DoubleBorder()).
			BorderForeground(lipgloss.AdaptiveColor{Light: "#B05900", Dark: "#E5A560"}).
			Padding(0, 2)

	styleOverlayTitle = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.AdaptiveColor{Light: "#B05900", Dark: "#E5A560"})

	styleWant = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.AdaptiveColor{Light: "#C0273B", Dark: "#F27E8B"})

	styleHelp = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#999999", Dark: "#5C5C5C"})
)
