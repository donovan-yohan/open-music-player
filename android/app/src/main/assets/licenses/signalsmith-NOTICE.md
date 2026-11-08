# Signalsmith native dependency notices

Bundled unmodified upstream source archives, verified at every CMake configure.
The archive contents include their full MIT notices. The two adjacent LICENSE
files are distributed notices and must accompany binary distribution.

- Signalsmith Stretch commit `88061fd4eda56a2353c5d65c74aa3f4ccf76f9da`.
  https://github.com/Signalsmith-Audio/signalsmith-stretch
  `stretch.tar.gz` SHA256 `4dc468e46f208415ca66567cacfd8fb22b01d321fcdb4c2452278fee2426b09d`.
- Signalsmith Linear `0.6.6`.
  https://github.com/Signalsmith-Audio/linear/tree/0.6.6
  `linear.tar.gz` SHA256 `e6d6a914189894fd728111b2a3209445ecd065aa9a5c1958f41b64ac3cef8b32`.

Portable built-in FFT only. No optional external FFT or GPL dependencies enabled.
`tempo_processor.cpp` is the project's worker adapter, not a modified upstream.
