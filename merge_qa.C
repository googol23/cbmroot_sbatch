// merge_qa.C
//
// Merge only explicitly selected ROOT objects.
//
// Called as:
//   root -l -b -q 'merge_qa.C("files.txt","merged.root")'

#include <TFile.h>
#include <TList.h>
#include <TObject.h>

#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <vector>
// -------------------------------------------------------------------------
// Hardcoded list of objects to merge.
// Paths are relative to the ROOT file root directory.
// -------------------------------------------------------------------------
const std::vector<std::string> selectedObjects = {
    // "CbmCaOutputQa/all/reco_p",	/* Total momentum of reconstructed track */
    // "CbmCaOutputQa/all/reco_pt",	/* Transverse momentum of reconstructed track */
    // "CbmCaOutputQa/all/reco_phi",	/* Azimuthal angle of reconstructed track */
    // "CbmCaOutputQa/all/reco_theta",	/* Polar angle of reconstructed track */
    // "CbmCaOutputQa/all/reco_theta_phi",	/* Polar angle vs. azimuthal angle of reconstructed track */
    // "CbmCaOutputQa/all/reco_tx",	/* Slope along x-axis of reconstructed tracks */
    // "CbmCaOutputQa/all/reco_ty",	/* Slope along y-axis of reconstructed tracks */
    // "CbmCaOutputQa/all/reco_ty_tx",	/* Slope along y-axis vs. x-axis of reconstructed tracks */
    // "CbmCaOutputQa/all/reco_eta",	/* Pseudorapidity of reconstructed track */
    // "CbmCaOutputQa/all/reco_fhitR",	/* Distance of the first hit from z-axis for reconstructed tracks */
    // "CbmCaOutputQa/all/reco_nhits",	/* Number of hits of reconstructed tracks */
    // "CbmCaOutputQa/all/reco_fsta",	/* First station index of reconstructed tracks */
    // "CbmCaOutputQa/all/reco_lsta",	/* Last station index of reconstructed tracks */
    // "CbmCaOutputQa/all/reco_chi2_ndf",	/* #chi^{2}/NDF of reconstructed tracks */
    // "CbmCaOutputQa/all/reco_chi2_ndf_time",	/* Time #chi^{2}/NDF of reconstructed tracks */
    // "CbmCaOutputQa/all/reco_pMC",	/* MC total momentum of reconstructed track */
    // "CbmCaOutputQa/all/reco_ptMC",	/* MC transverse momentum of reconstructed track */
    // "CbmCaOutputQa/all/reco_yMC",	/* MC rapidity of reconstructed track */
    // "CbmCaOutputQa/all/reco_etaMC",	/* MC pseudorapidity of reconstructed track */
    // "CbmCaOutputQa/all/reco_ptMC_yMC",	/* MC Transverse momentum of reconstructed track */
    // "CbmCaOutputQa/all/reco_phiMC",	/* MC Azimuthal angle of reconstructed track */
    // "CbmCaOutputQa/all/reco_thetaMC",	/* MC Polar angle of reconstructed track */
    // "CbmCaOutputQa/all/reco_thetaMC_phiMC",	/* MC Polar angle vs. MC azimuthal angle of reconstructed track */
    // "CbmCaOutputQa/all/reco_txMC",	/* MC Slope along x-axis of reconstructed tracks */
    // "CbmCaOutputQa/all/reco_tyMC",	/* MC Slope along y-axis of reconstructed tracks */
    // "CbmCaOutputQa/all/mc_pMC",	/* Total momentum of MC tracks */
    // "CbmCaOutputQa/all/mc_ptMC",	/* Transverse momentum of MC track */
    // "CbmCaOutputQa/all/mc_etaMC",	/* Pseudorapidity of MC tracks */
    // "CbmCaOutputQa/all/mc_yMC",	/* Rapidity of MC tracks */
    // "CbmCaOutputQa/all/mc_ptMC_yMC",	/* Transverse momentum vs. rapidity of MC tracks */
    // "CbmCaOutputQa/all/mc_phiMC",	/* Azimuthal angle of MC track */
    // "CbmCaOutputQa/all/mc_thetaMC",	/* Polar angle of MC track */
    // "CbmCaOutputQa/all/mc_thetaMC_phiMC",	/* Polar angle vs. azimuthal angle of MC track */
    // "CbmCaOutputQa/all/mc_txMC",	/* Slope along x-axis of MC tracks */
    // "CbmCaOutputQa/all/mc_tyMC",	/* Slope along y-axis of MC tracks */
    // "CbmCaOutputQa/all/mc_tyMC_txMC",	/* Slope along y-axis vs. x-axis of MC tracks */
    // 
    "CbmCaOutputQa/prim/reco_pMC",	/* Total momentum of MC tracks */
    "CbmCaOutputQa/prim/reco_ptMC",	/* Transverse momentum of MC track */
    "CbmCaOutputQa/prim/mc_pMC",	/* Total momentum of MC tracks */
    "CbmCaOutputQa/prim/mc_ptMC",	/* Transverse momentum of MC track */
};

void merge_qa(const char* fileList, const char* outputFile)
{

    std::ifstream list(fileList);
    if (!list) {
        std::cerr << "ERROR: Cannot open file list: "
                  << fileList << '\n';
        return;
    }

    std::vector<std::string> files;
    std::string filename;

    while (std::getline(list, filename)) {
        if (!filename.empty())
            files.push_back(filename);
    }

    if (files.empty()) {
        std::cerr << "ERROR: File list is empty.\n";
        return;
    }

    TFile output(outputFile, "RECREATE");

    if (output.IsZombie()) {
        std::cerr << "ERROR: Cannot create output file: "
                  << outputFile << '\n';
        return;
    }

    for (const auto& objectPath : selectedObjects) {

        std::unique_ptr<TH1> merged;

        for (const auto& inputName : files) {

            TFile input(inputName.c_str(), "READ");

            if (input.IsZombie()) {
                std::cerr << "WARNING: Cannot open "
                          << inputName << '\n';
                continue;
            }

            TH1* h = nullptr;
            input.GetObject(objectPath.c_str(), h);

            if (!h) {
                std::cerr << "WARNING: Histogram "
                          << objectPath
                          << " not found in "
                          << inputName << '\n';
                continue;
            }

            if (!merged) {
                merged.reset(
                    dynamic_cast<TH1*>(h->Clone())
                );

                // Detach histogram from the input TFile.
                merged->SetDirectory(nullptr);
            }
            else {
                if (!merged->Add(h)) {
                    std::cerr
                        << "ERROR: Cannot add "
                        << objectPath
                        << " from "
                        << inputName << '\n';
                }
            }
        }

        if (!merged) {
            std::cerr << "WARNING: No instances found for "
                      << objectPath << '\n';
            continue;
        }

        output.cd();
        merged->Write();

        std::cout << "Merged: "
                  << objectPath << '\n';
    }

    output.Close();

    std::cout << "Output written to: "
              << outputFile << '\n';
}
