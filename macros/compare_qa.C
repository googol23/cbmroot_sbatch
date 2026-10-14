#include <TCanvas.h>
#include <TClass.h>
#include <TDirectory.h>
#include <TFile.h>
#include <TH1.h>
#include <TH2.h>
#include <TKey.h>
#include <TSystem.h>

#include <cmath>
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>


// ============================================================
// Comparison objects
// ============================================================
std::vector<std::string> elements = {
  // "CbmCaOutputQa/all/reco_theta_phi",
  // "CbmCaOutputQa/all/reco_ty_tx",
  // "CbmCaOutputQa/all/reco_ptMC_yMC",
  // "CbmCaOutputQa/all/reco_thetaMC_phiMC",
  // "CbmCaOutputQa/all/mc_ptMC_yMC",
  // "CbmCaOutputQa/all/mc_thetaMC_phiMC",
  // "CbmCaOutputQa/all/mc_tyMC_txMC",
  "CbmCaOutputQa/all/eff_pMC"
  // "CbmCaOutputQa/all/eff_theta_phi",
  // "CbmCaOutputQa/all/clone_ptMC_yMC",
  // "CbmCaOutputQa/all/clone_theta_phi"
};

// ============================================================
// File validation
// ============================================================
void check_file(TFile* file, const std::string& label)
{
  if (!file || file->IsZombie()) {
    std::cerr << "ERROR: cannot open " << label << std::endl;
    gSystem->Exit(1);
  }
}


// ============================================================
// Histogram discovery
// ============================================================
struct ListTH {
  std::vector<std::string> th1;
  std::vector<std::string> th2;
};


ListTH GetTHPaths(TFile* file)
{
  ListTH result;

  if (!file || file->IsZombie()) return result;

  auto scan = [&](auto&& self, TDirectory* dir, const std::string& path) -> void {
    TIter next(dir->GetListOfKeys());

    while (TKey* key = static_cast<TKey*>(next())) {
      TClass* cls = TClass::GetClass(key->GetClassName());
      if (!cls) continue;

      const std::string name     = key->GetName();
      const std::string fullPath = path.empty() ? name : path + "/" + name;

      // ------------------------------------------------------
      // Directory
      // ------------------------------------------------------
      if (cls->InheritsFrom(TDirectory::Class())) {
        TDirectory* subdir = dir->GetDirectory(name.c_str());
        if (subdir) self(self, subdir, fullPath);
        continue;
      }

      // ------------------------------------------------------
      // Histogram
      // ------------------------------------------------------

      if (!cls->InheritsFrom(TH1::Class())) continue;

      TH1* hist = nullptr;
      dir->GetObject(name.c_str(), hist);

      if (!hist) continue;

      switch (hist->GetDimension()) {
        case 1: result.th1.push_back(fullPath); break;
        case 2: result.th2.push_back(fullPath); break;
        default: break;
      }
    }
  };

  scan(scan, file, "");
  return result;
}


// ============================================================
// Comparison result
// ============================================================
struct THComparison {
  double chi2 = 0.0;
  int ndof    = 0;

  std::unique_ptr<TH1> comparison;
  std::unique_ptr<TH1> chi2Map;

  void dump(TFile* file, const std::string& directoryName)
  {
    if (!file || file->IsZombie()) return;

    file->cd();

    TDirectory* dir = file->GetDirectory(directoryName.c_str());

    if (!dir) dir = file->mkdir(directoryName.c_str());

    if (!dir) return;

    dir->cd();

    if (comparison) comparison->Write("comparison");

    if (chi2Map) chi2Map->Write("chi2_map");

    file->cd();
  }
};
// ============================================================
// Bin operation
// ============================================================
double NormalizedDifference(double x1, double x2)
{
  const double denominator = x1 + x2;
  if (denominator == 0.0) return 0.0;
  return (x1 - x2) / denominator;
}

// ============================================================
// TH comparison
// ============================================================
THComparison CompareTH(const TH1* h1, const TH1* h2, const std::function<double(double, double)>& operation)
{
  if (!h1 || !h2) throw std::invalid_argument("CompareTH: null histogram");

  const int dimension = h1->GetDimension();

  if (dimension != h2->GetDimension()) throw std::invalid_argument("CompareTH: histograms have different dimensions");

  if (dimension != 1 && dimension != 2)
    throw std::invalid_argument("CompareTH: only 1D and 2D histograms are supported");

  // ========================================================
  // Check bin counts
  // ========================================================

  if (h1->GetNbinsX() != h2->GetNbinsX()) throw std::invalid_argument("CompareTH: different X bin counts");

  if (dimension == 2 && h1->GetNbinsY() != h2->GetNbinsY())
    throw std::invalid_argument("CompareTH: different Y bin counts");

  // ========================================================
  // Check X-axis binning
  // ========================================================

  for (int ix = 1; ix <= h1->GetNbinsX() + 1; ++ix) {

    if (h1->GetXaxis()->GetBinLowEdge(ix) != h2->GetXaxis()->GetBinLowEdge(ix)) {

      throw std::invalid_argument("CompareTH: incompatible X-axis binning");
    }
  }

  // ========================================================
  // Check Y-axis binning
  // ========================================================

  if (dimension == 2) {

    for (int iy = 1; iy <= h1->GetNbinsY() + 1; ++iy) {

      if (h1->GetYaxis()->GetBinLowEdge(iy) != h2->GetYaxis()->GetBinLowEdge(iy)) {

        throw std::invalid_argument("CompareTH: incompatible Y-axis binning");
      }
    }
  }

  THComparison result;

  // ========================================================
  // Clone output histograms
  // ========================================================

  result.comparison.reset(static_cast<TH1*>(h1->Clone("comparison")));

  result.chi2Map.reset(static_cast<TH1*>(h1->Clone("chi2_map")));

  result.comparison->Reset("ICES");
  result.chi2Map->Reset("ICES");

  result.comparison->SetDirectory(nullptr);
  result.chi2Map->SetDirectory(nullptr);

  result.comparison->SetTitle("Bin-by-bin comparison");

  result.chi2Map->SetTitle("#chi^{2} contribution per bin");

  // ========================================================
  // Loop over bins
  // ========================================================

  const int nx = h1->GetNbinsX();
  const int ny = (dimension == 2) ? h1->GetNbinsY() : 1;

  for (int ix = 1; ix <= nx; ++ix) {

    for (int iy = 1; iy <= ny; ++iy) {

      const int bin1 = (dimension == 1) ? h1->GetBin(ix) : h1->GetBin(ix, iy);

      const int bin2 = (dimension == 1) ? h2->GetBin(ix) : h2->GetBin(ix, iy);

      const double v1 = h1->GetBinContent(bin1);

      const double v2 = h2->GetBinContent(bin2);

      const double e1 = h1->GetBinError(bin1);

      const double e2 = h2->GetBinError(bin2);

      // ====================================================
      // External bin-by-bin comparison operation
      // ====================================================

      result.comparison->SetBinContent(bin1, operation(v1, v2));

      // ====================================================
      // Chi2 contribution
      // ====================================================

      const double variance = e1 * e1 + e2 * e2;

      if (variance <= 0.0) continue;

      const double delta = v1 - v2;

      const double chi2Bin = delta * delta / variance;

      result.chi2 += chi2Bin;

      result.chi2Map->SetBinContent(bin1, chi2Bin);

      ++result.ndof;
    }
  }

  return result;
}
// ============================================================
// Sanitize ROOT path for use as directory name
// ============================================================
std::string sanitize_name(std::string name)
{
  for (char& c : name) {
    if (c == '/') c = '_';
  }
  return name;
}

// ============================================================
// Main comparison
// ============================================================
void compare_qa(
  const char* file_name_0 = "/lustre/cbm/users/dramirez/mc/out/qa/1/1.qa.root",
  const char* file_name_1 = "/lustre/cbm/users/dramirez/mc/out/event_based/inactive_channel/qa/1/1.qa.root")
{
  std::unique_ptr<TFile> f1(TFile::Open(file_name_0, "READ"));
  std::unique_ptr<TFile> f2(TFile::Open(file_name_1, "READ"));

  check_file(f1.get(), "input file 1");
  check_file(f2.get(), "input file 2");

  std::cout << "\n"
            << "==========================================\n"
            << "ROOT histogram comparison\n"
            << "==========================================\n"
            << "Input 1:\n"
            << file_name_0 << '\n'
            << "Input 2:\n"
            << file_name_1 << "\n\n";

  std::unique_ptr<TFile> out(TFile::Open("compare_test.root", "RECREATE"));

  check_file(out.get(), "output file");

  // Use explicit list if provided.
  // Otherwise compare every TH1/TH2 found in input 1.
  std::vector<std::string> paths = elements;

  if (paths.empty()) {
    const auto found = GetTHPaths(f1.get());

    paths.insert(paths.end(), found.th1.begin(), found.th1.end());
    paths.insert(paths.end(), found.th2.begin(), found.th2.end());
  }

  int compared = 0;
  int missing  = 0;
  int failed   = 0;

  for (const auto& path : paths) {

    TH1* h1 = nullptr;
    TH1* h2 = nullptr;

    f1->GetObject(path.c_str(), h1);
    f2->GetObject(path.c_str(), h2);

    if (!h1 || !h2) {
      std::cerr << "WARNING: missing histogram: " << path << '\n';
      ++missing;
      continue;
    }

    try {
      auto comparison = CompareTH(h1, h2, NormalizedDifference);

      comparison.dump(out.get(), sanitize_name(path));

      std::cout << path << "  chi2=" << comparison.chi2 << "  ndof=" << comparison.ndof;

      if (comparison.ndof > 0) std::cout << "  chi2/ndof=" << comparison.chi2 / comparison.ndof;

      std::cout << '\n';

      ++compared;
    }
    catch (const std::exception& e) {
      std::cerr << "ERROR comparing " << path << ": " << e.what() << '\n';

      ++failed;
    }
  }

  out->Write();
  out->Close();

  std::cout << "\n==========================================\n"
            << "Compared : " << compared << '\n'
            << "Missing  : " << missing << '\n'
            << "Failed   : " << failed << '\n'
            << "==========================================\n";
}