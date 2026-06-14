#include <cpp11.hpp>

// Scaffold placeholder for the cpp11 matcher core. This exists so the compiled
// toolchain (LinkingTo: cpp11, registration, dynamic library load) is wired and
// exercised from the first commit. The real partitioned rule indexes and the
// prevailing-rule algorithm replace this in later phases (see docs/PRD.md s8.2).
[[cpp11::register]]
std::string pslr_engine_id() {
  return "pslr-cpp11-scaffold";
}
