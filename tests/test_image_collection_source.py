"""Source wiring checks; runtime behavior is tested by native/real-SDK suites."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]


class ImageCollectionWiring(unittest.TestCase):
    def test_runtime_uses_image_only_overlay_and_original_base_identity(self):
        text=(ROOT/'AxsCacheKeeperImageCacheRuntime.m').read_text(encoding='utf-8-sig')
        self.assertIn('axs_cachekeeper_image_collection_context',text)
        self.assertLess(text.index('BOOL installationRequested='),text.index('axs_cachekeeper_image_collection_context'))
        self.assertIn('AxsCacheKeeperImageCollectionChanged',text)

    def test_writer_expiry_revokes_attribution_before_deciding(self):
        text=(ROOT/'AxsCacheKeeperImageCache.m').read_text(encoding='utf-8-sig')
        self.assertIn('collectionDeadline',text)
        self.assertIn('requestCollectionExpiryRefresh',text)
        self.assertIn('sameEpoch && leaseValid',text)

    def test_ui_does_not_write_user_configuration(self):
        text=(ROOT/'Prefs/ImageCollectionPage.m').read_text(encoding='utf-8-sig')
        self.assertIn('取消并恢复当前设置',text)
        self.assertNotIn('writeToFile',text)


if __name__=='__main__': unittest.main()
