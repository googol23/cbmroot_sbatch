#include <regex>
#include <stdexcept>
#include <string>
#include <vector>
#include "CbmStsDigiQa.h"

std::vector<int> ExtractJobsId(const std::string& input)
{
  std::vector<int> result;

  // Matches either:
  //   12       -> single ID
  //   12-15    -> range
  //   12..15   -> range
  //
  // Whitespace around range separators is allowed.
  static const std::regex pattern(R"((\d+)(?:\s*(?:-|\.\.)\s*(\d+))?)");

  for (std::sregex_iterator it(input.begin(), input.end(), pattern), end; it != end; ++it) {
    const int first = std::stoi((*it)[1].str());

    if ((*it)[2].matched) {
      const int last = std::stoi((*it)[2].str());

      if (first > last) throw std::invalid_argument("Invalid descending job ID range");

      for (int id = first; id <= last; ++id)
        result.push_back(id);
    }
    else {
      result.push_back(first);
    }
  }

  return result;
}


void run_qa_digi_manual(std::string data_set_path, std::string jobs)
{
  FairLogger::GetLogger()->SetLogScreenLevel("INFO");

  fair::Logger::DefineVerbosity(
    "user1", fair::VerbositySpec::Make(fair::VerbositySpec::Info::severity, fair::VerbositySpec::Info::file_line));

  FairLogger::GetLogger()->SetLogVerbosityLevel("user1");
  FairLogger::GetLogger()->SetColoredLog(true);

  TString setup = "sis100_electron";
  int  nEvents = -1;
  TString sEvBuildRaw = "Ideal";
  constexpr bool bUseMC = true;
  constexpr int verbose = 3;

  const TString myName = "run_qa";
  const TString srcDir = gSystem->Getenv("VMCWORKDIR");

  // -------------------------------------------------------------------------
  // Setup
  // -------------------------------------------------------------------------
  std::cout << "\n-I- " << myName << ": Loading setup " << setup << std::endl;
  auto* geo = CbmSetup::Instance();
  geo->LoadSetup(setup);
  const ECbmRecoMode recoMode = !sEvBuildRaw.IsNull() ? ECbmRecoMode::EventByEvent : ECbmRecoMode::Timeslice;
  const bool bUseSts          = geo->IsActive(ECbmModuleId::kSts);
  std::cout << "  STS: " << (bUseSts ? "ON" : "OFF") << '\n';

  // -------------------------------------------------------------------------
  // Timer
  // -------------------------------------------------------------------------
  TStopwatch timer;
  timer.Start();
  gDebug = 0;

  // -------------------------------------------------------------------------
  // I/O files
  // -------------------------------------------------------------------------
  auto jobs_id      = ExtractJobsId(jobs);
  FairFileSource* inputSource = nullptr;
  // Add the remaining digitization files to the primary input chain.
  for (auto& id : jobs_id) {
    // std::string f_raw_name = data_set_path + Form("/%d/%d.digi.root", id, id);
    std::string f_raw_name = data_set_path + Form("/urqmd.auau.p12.bmax6.71.%05d.digi.root", id);
    std::cout << "Adding files to input: " << f_raw_name << std::endl;
    if (inputSource == nullptr){
      inputSource = new FairFileSource(f_raw_name);
    }else{
      inputSource->AddFile(f_raw_name.c_str());      
    }    
  }

  // TString dataSink = data_set_path + "/qa_digi.root";
  TString dataSink = "./qa_digi.root";
  
  // -------------------------------------------------------------------------
  // FairRun
  // -------------------------------------------------------------------------
  auto* run = new FairRunAna();
  run->SetSource(inputSource);
  run->SetGenerateRunInfo(kFALSE);
  run->SetSink(new FairRootFileSink(dataSink));

  // -------------------------------------------------------------------------
  // QA manager
  // -------------------------------------------------------------------------
  auto* qaManager = new CbmQaManager(verbose);
  run->AddTask(qaManager);
  // -------------------------------------------------------------------------
  // STS input QA
  // -------------------------------------------------------------------------
  if (bUseSts) {
    qaManager->AddTask(new cbm::qa::CbmStsDigiQa(verbose, bUseMC, 0, 1, std::nullopt));
  }

  // -------------------------------------------------------------------------
  // Initialise
  // -------------------------------------------------------------------------
  std::cout << "\n-I- " << myName << ": Initialise run" << std::endl;

  run->Init();

  // -------------------------------------------------------------------------
  // Run
  // -------------------------------------------------------------------------
  std::cout << "\n\n-I- " << myName << ": Starting run" << std::endl;
  run->Run(0, nEvents);

  // -------------------------------------------------------------------------
  // Finish
  // -------------------------------------------------------------------------
  timer.Stop();
  FairMonitor::GetMonitor()->Print();
  const Double_t realTime = timer.RealTime();
  const Double_t cpuTime  = timer.CpuTime();
  std::cout << "\n\nMacro finished successfully.\n"
            << "Output file is " << dataSink << '\n'
            << "Real time " << realTime << " s, CPU time " << cpuTime << " s\n\n"
            << " QA checks " << (qaManager->GetStatus() ? "\e[1;32mpassed" : "\e[1;31mfailed") << "\e[0m\n"
            << " Test passed\n All ok " << std::endl;
}