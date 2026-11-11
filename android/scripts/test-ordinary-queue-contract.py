#!/usr/bin/env python3
"""Source adoption checks. These do not claim mounted UI/transport execution."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
PANEL = ROOT / 'app/src/main/kotlin/com/soundq/android/product/QueuePanel.kt'
CONTROLLER = ROOT / 'app/src/main/kotlin/com/soundq/android/playback/ControllerProjection.kt'

class OrdinaryQueueContract(unittest.TestCase):
    def test_more_is_a_border_free_workspace_cell(self):
        self.assertIn('SoundQIconButton(SoundQIcon.More,"Queue actions",{menu=true},outlined=false)', PANEL.read_text())

    def test_clear_requires_explicit_captured_confirmation(self):
        source = PANEL.read_text()
        self.assertIn('Text("Clear listening queue")', source)
        self.assertIn('clear=QueueClearCapture(playback)', source)
        self.assertIn('title={Text("Clear listening queue?")}', source)
        self.assertIn('"Playback stops. Library songs, downloads and server imports stay."', source)
        self.assertIn('capture.confirm(model.playback.value,valid,model.controller::clear)', source)
        self.assertIn('dismissButton={SoundQButton("Keep queue"', source)
        self.assertNotIn('manageQueue(', source)
        self.assertNotIn('graph.imports', source)

    def test_controller_clear_uses_the_existing_player_command_only(self):
        self.assertIn('fun clear(){retireScratch();controller?.clearMediaItems()}', CONTROLLER.read_text())

if __name__ == '__main__':
    unittest.main()
