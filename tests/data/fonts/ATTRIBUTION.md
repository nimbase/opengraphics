# Test font provenance
#
# ai-micro.ttf is a subset of DejaVuSans (DejaVu fonts, Bitstream Vera
# license: free to redistribute with the copyright and licence notice).
# Built with `hb-subset` 14.2.1:
#
#   hb-subset --unicodes="U+0020-007E,U+FB01" --layout-features='*' \
#     --no-hinting --output-file=ai-micro.ttf DejaVuSans.ttf
#
# Printable ASCII plus U+FB01 (so the `fi` ligature survives), 15.7K.
# Enough to shape, kern, ligate, and outline Latin test strings.
# The full DejaVu licence text lives next to the source font in the
# opendocs package (tests/data/fonts/LICENSE.dejavu.txt).
