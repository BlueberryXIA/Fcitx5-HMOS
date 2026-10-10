// Reproduces the exact OpenCC call sequence librime uses in Opencc::Initialize()
// so we can see what happens when the configured conversion file is missing.
//
// librime does:
//     converter_ = config.NewFromFile(path);
//     const auto conversions = converter_->GetConversionChain()->GetConversions();
//
// The second line dereferences converter_ unconditionally.

#include <opencc/Config.hpp>
#include <opencc/Conversion.hpp>
#include <opencc/ConversionChain.hpp>
#include <opencc/Converter.hpp>

#include <iostream>
#include <string>

namespace {

void Probe(const std::string& path) {
  std::cout << "--- " << path << "\n";
  try {
    opencc::Config config;
    auto converter = config.NewFromFile(path);
    std::cout << "    converter=" << static_cast<const void*>(converter.get()) << "\n";
    if (!converter) {
      std::cout << "    (null conversion returned without throwing)\n";
      return;
    }
    auto chain = converter->GetConversionChain();
    std::cout << "    chain=" << static_cast<const void*>(chain.get()) << "\n";
    if (!chain) {
      std::cout << "    (null chain -- librime segfaults on the next line)\n";
      return;
    }
    std::cout << "    conversions=" << chain->GetConversions().size() << "\n";
  } catch (const std::exception& e) {
    std::cout << "    threw std::exception: " << e.what() << "\n";
  } catch (...) {
    std::cout << "    threw something unknown\n";
  }
}

}  // namespace

int main(int argc, char** argv) {
  for (int i = 1; i < argc; ++i) {
    Probe(argv[i]);
  }
  return 0;
}
