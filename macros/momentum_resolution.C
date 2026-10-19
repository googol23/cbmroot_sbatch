#include <TDirectory.h>
#include <TF1.h>
#include <TFile.h>
#include <TFitResult.h>
#include <TFitResultPtr.h>
#include <TGraphErrors.h>
#include <TH1D.h>
#include <TH2.h>
#include <TPaveText.h>
#include <TString.h>

#include <algorithm>
#include <cmath>
#include <iostream>
#include <memory>

struct WidthMeasurement {
  double value = 0.0;
  double error = 0.0;
  bool valid = false;
};

WidthMeasurement measure_fwhm(const TH1D& histogram)
{
  const int maximumBin = histogram.GetMaximumBin();
  const double halfMaximum = 0.5 * histogram.GetBinContent(maximumBin);
  if (halfMaximum <= 0.0) return {};

  int leftBin = maximumBin;
  while (leftBin > 1 && histogram.GetBinContent(leftBin) >= halfMaximum)
    --leftBin;

  int rightBin = maximumBin;
  while (rightBin < histogram.GetNbinsX() && histogram.GetBinContent(rightBin) >= halfMaximum)
    ++rightBin;

  if ((leftBin == 1 && histogram.GetBinContent(leftBin) >= halfMaximum)
      || (rightBin == histogram.GetNbinsX() && histogram.GetBinContent(rightBin) >= halfMaximum))
    return {};

  auto interpolate = [&](int bin1, int bin2) {
    const double x1 = histogram.GetXaxis()->GetBinCenter(bin1);
    const double x2 = histogram.GetXaxis()->GetBinCenter(bin2);
    const double y1 = histogram.GetBinContent(bin1);
    const double y2 = histogram.GetBinContent(bin2);
    if (y1 == y2) return 0.5 * (x1 + x2);
    return x1 + (halfMaximum - y1) * (x2 - x1) / (y2 - y1);
  };

  const double leftCrossing = interpolate(leftBin, leftBin + 1);
  const double rightCrossing = interpolate(rightBin - 1, rightBin);

  WidthMeasurement result;
  result.value = rightCrossing - leftCrossing;
  result.error = std::hypot(0.5 * histogram.GetXaxis()->GetBinWidth(leftBin),
                            0.5 * histogram.GetXaxis()->GetBinWidth(rightBin));
  result.valid = result.value > 0.0;
  return result;
}

void momentum_resolution(
  const char* inputFile = "qa_innactive_merged.root",
  const char* histogramPath = "reco_minus_mc_p_vs_mc_p;3",
  const char* outputFile = "momentum_resolution.root",
  double minEntries = 20.0)
{
  std::unique_ptr<TFile> input(TFile::Open(inputFile, "READ"));
  if (!input || input->IsZombie()) {
    std::cerr << "ERROR: cannot open " << inputFile << '\n';
    return;
  }

  TH2* source = nullptr;
  input->GetObject(histogramPath, source);
  if (!source) {
    std::cerr << "ERROR: cannot find TH2 " << histogramPath << '\n';
    return;
  }

  const int nx = source->GetNbinsX();

  std::unique_ptr<TFile> output(TFile::Open(outputFile, "RECREATE"));
  if (!output || output->IsZombie()) {
    std::cerr << "ERROR: cannot create " << outputFile << '\n';
    return;
  }

  output->cd();
  source->Write("delta_p_vs_mc_p");

  TDirectory* projections = output->mkdir("projections");
  auto resolution = std::make_unique<TGraphErrors>();
  resolution->SetName("sigma_over_p_vs_mc_p");
  resolution->SetTitle("Relative momentum resolution;p_{MC};#sigma(p_{reco}-p_{MC})/p_{MC} [%]");

  auto rmsResolution = std::make_unique<TGraphErrors>();
  rmsResolution->SetName("rms_over_p_vs_mc_p");
  rmsResolution->SetTitle("Relative RMS;p_{MC};RMS(p_{reco}-p_{MC})/p_{MC} [%]");

  auto fwhmResolution = std::make_unique<TGraphErrors>();
  fwhmResolution->SetName("fwhm_over_p_vs_mc_p");
  fwhmResolution->SetTitle("Relative FWHM;p_{MC};FWHM(p_{reco}-p_{MC})/p_{MC} [%]");

  int sigmaPoint = 0;
  int rmsPoint = 0;
  int fwhmPoint = 0;
  for (int ix = 1; ix <= nx; ++ix) {
    std::unique_ptr<TH1D> projection(source->ProjectionY(Form("delta_p_bin_%03d", ix), ix, ix, "e"));
    projection->SetDirectory(nullptr);
    projection->SetTitle(Form("p_{MC} in [%.4g, %.4g);p_{reco}-p_{MC};Entries",
                              source->GetXaxis()->GetBinLowEdge(ix),
                              source->GetXaxis()->GetBinUpEdge(ix)));

    const double mcP = source->GetXaxis()->GetBinCenter(ix);
    const double pError = 0.5 * source->GetXaxis()->GetBinWidth(ix);
    const double rms = projection->GetRMS();

    if (projection->Integral() >= minEntries && rms > 0.0 && mcP > 0.0) {
      const double rmsError = projection->GetRMSError();
      const double relativeRms = 100.0 * rms / mcP;
      const double relativeRmsError =
        100.0 * std::hypot(rmsError / mcP, rms * pError / (mcP * mcP));
      rmsResolution->SetPoint(rmsPoint, mcP, relativeRms);
      rmsResolution->SetPointError(rmsPoint, pError, relativeRmsError);
      ++rmsPoint;

      const WidthMeasurement fwhm = measure_fwhm(*projection);
      if (fwhm.valid) {
        const double relativeFwhm = 100.0 * fwhm.value / mcP;
        const double relativeFwhmError =
          100.0 * std::hypot(fwhm.error / mcP, fwhm.value * pError / (mcP * mcP));
        fwhmResolution->SetPoint(fwhmPoint, mcP, relativeFwhm);
        fwhmResolution->SetPointError(fwhmPoint, pError, relativeFwhmError);
        ++fwhmPoint;
      }

      const double fitMin = std::max(source->GetYaxis()->GetXmin(), projection->GetMean() - 3.0 * rms);
      const double fitMax = std::min(source->GetYaxis()->GetXmax(), projection->GetMean() + 3.0 * rms);
      TFitResultPtr fit = projection->Fit("gaus", "QS", "", fitMin, fitMax);
      TF1* gaussian = projection->GetFunction("gaus");

      if (fit.Get() && fit->Status() == 0 && gaussian && gaussian->GetParameter(2) > 0.0) {
        auto* fitInfo = new TPaveText(0.58, 0.62, 0.88, 0.88, "NDC");
        fitInfo->SetName("fit_info");
        fitInfo->SetFillStyle(0);
        fitInfo->SetBorderSize(1);
        fitInfo->SetTextAlign(12);
        fitInfo->SetTextSize(0.03);
        fitInfo->AddText(Form("Fit range: [%.4g, %.4g]", fitMin, fitMax));
        fitInfo->AddText(Form("#chi^{2}/NDF: %.4g/%d", fit->Chi2(), fit->Ndf()));
        fitInfo->AddText(Form("Mean: %.4g #pm %.2g", gaussian->GetParameter(1), gaussian->GetParError(1)));
        fitInfo->AddText(Form("Sigma: %.4g #pm %.2g", gaussian->GetParameter(2), gaussian->GetParError(2)));
        projection->GetListOfFunctions()->Add(fitInfo);

        const double sigma = gaussian->GetParameter(2);
        const double sigmaError = gaussian->GetParError(2);
        const double relativeSigma = 100.0 * sigma / mcP;
        const double relativeSigmaError =
          100.0 * std::hypot(sigmaError / mcP, sigma * pError / (mcP * mcP));

        resolution->SetPoint(sigmaPoint, mcP, relativeSigma);
        resolution->SetPointError(sigmaPoint, pError, relativeSigmaError);
        ++sigmaPoint;
      }
    }

    projections->cd();
    projection->Write();
  }

  output->cd();
  resolution->Write();
  rmsResolution->Write();
  fwhmResolution->Write();
  output->Close();

  std::cout << "Wrote " << outputFile << " with " << sigmaPoint << " Gaussian, " << rmsPoint << " RMS, and "
            << fwhmPoint << " FWHM points.\n";
}
