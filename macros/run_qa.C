/* Copyright (C) 2006-2020 GSI Helmholtzzentrum fuer Schwerionenforschung, Darmstadt
   SPDX-License-Identifier: GPL-3.0-only
   Authors: Sergey Gorbunov, Denis Bertini [committer], Florian Uhlig, Sergei Zharko */

// QA macro containing only the active STS and CA tracking QA path.

#include <vector>

#if !defined(__CLING__)
#include "CbmDefs.h"
#include "CbmMCDataManager.h"
#include "CbmSetup.h"

#include <FairFileSource.h>
#include <FairMonitor.h>
#include <FairParRootFileIo.h>
#include <FairRootFileSink.h>
#include <FairRunAna.h>
#include <FairRuntimeDb.h>
#include <FairSystemInfo.h>

#include <TObjArray.h>
#include <TObjString.h>
#include <TROOT.h>
#include <TStopwatch.h>
#include <TString.h>
#include <TSystem.h>

#include <Logger>
#include <iostream>
#include <memory>
#endif


// ---------------------------------------------------------------------------
// Forward declaration of the vector-based implementation
// ---------------------------------------------------------------------------

void run_qa(const std::vector<TString>& dataTraColl, const std::vector<TString>& dataRaw,
            const std::vector<TString>& dataReco, TString dataPar, TString dataSink, TString setup, Int_t nEvents,
            const std::vector<TString>& dataTraSign, const std::vector<TString>& dataTraBeam, TString config,
            TString sEvBuildRaw, TString sBenchmark);


// ---------------------------------------------------------------------------
// Helper: add one pipeline task/chunk to the input collections
// ---------------------------------------------------------------------------

void add_qa_input(Int_t id, const TString& outputDir, std::vector<TString>& traFiles, std::vector<TString>& rawFiles,
                  std::vector<TString>& recoFiles)
{
  traFiles.emplace_back(TString::Format("%s/tra/%d/%d.tra.root", outputDir.Data(), id, id));

  rawFiles.emplace_back(TString::Format("%s/raw/%d/%d.digi.root", outputDir.Data(), id, id));

  recoFiles.emplace_back(TString::Format("%s/rec/%d/%d.reco.root", outputDir.Data(), id, id));
}


// ---------------------------------------------------------------------------
// Pipeline interface
//
// Instead of passing hundreds of filenames through ROOT's command line,
// pass only:
//
//   outputDir
//   taskRange
//   setup
//   nEvents
//
// Examples:
//
//   run_qa("/path/to/default", "101-200")
//   run_qa("/path/to/default", "101-200", "sis100_electron", -1)
//   run_qa("/path/to/default", "101-120,125,130-150", "sis100_electron", -1)
//
// The file names are constructed internally from the pipeline directory
// structure.
// ---------------------------------------------------------------------------

void run_qa(TString outputDir, TString taskRange, TString setup = "sis100_electron", Int_t nEvents = -1)
{
  const TString myName = "run_qa";

  std::vector<Int_t> taskIds;

  std::vector<TString> traFiles;
  std::vector<TString> rawFiles;
  std::vector<TString> recoFiles;


  // -------------------------------------------------------------------------
  // Normalise output directory
  // -------------------------------------------------------------------------

  outputDir = outputDir.Strip(TString::kBoth);

  while (outputDir.EndsWith("/")) {
    outputDir.Chop();
  }

  if (outputDir.IsNull()) {
    std::cerr << "-E- " << myName << ": Empty output directory." << std::endl;

    return;
  }


  // -------------------------------------------------------------------------
  // Parse task range
  //
  // Supported forms:
  //
  //   101
  //   101-200
  //   101,105,110
  //   101-120,130,150-170
  // -------------------------------------------------------------------------

  taskRange = taskRange.Strip(TString::kBoth);

  if (taskRange.IsNull()) {
    std::cerr << "-E- " << myName << ": Empty task range." << std::endl;

    return;
  }

  std::unique_ptr<TObjArray> parts(taskRange.Tokenize(","));

  if (!parts || parts->GetEntries() == 0) {
    std::cerr << "-E- " << myName << ": Cannot parse task range: " << taskRange << std::endl;

    return;
  }

  for (Int_t iPart = 0; iPart < parts->GetEntries(); ++iPart) {

    auto* obj = dynamic_cast<TObjString*>(parts->At(iPart));

    if (!obj) {
      std::cerr << "-E- " << myName << ": Cannot parse task range: " << taskRange << std::endl;

      return;
    }

    TString part = obj->GetString();

    part = part.Strip(TString::kBoth);

    if (part.IsNull()) {
      std::cerr << "-E- " << myName << ": Empty component in task range: " << taskRange << std::endl;

      return;
    }

    const Ssiz_t dash = part.Index("-");


    // -----------------------------------------------------------------------
    // Single task ID
    // -----------------------------------------------------------------------

    if (dash == kNPOS) {

      if (!part.IsDigit()) {
        std::cerr << "-E- " << myName << ": Invalid task ID: " << part << std::endl;

        return;
      }

      taskIds.push_back(part.Atoi());

      continue;
    }


    // -----------------------------------------------------------------------
    // Task range: first-last
    // -----------------------------------------------------------------------

    if (part.Index("-", dash + 1) != kNPOS) {
      std::cerr << "-E- " << myName << ": Invalid task range: " << part << std::endl;

      return;
    }

    TString first = part(0, dash);

    TString last = part(dash + 1, part.Length() - dash - 1);

    first = first.Strip(TString::kBoth);
    last  = last.Strip(TString::kBoth);

    if (first.IsNull() || last.IsNull() || !first.IsDigit() || !last.IsDigit()) {

      std::cerr << "-E- " << myName << ": Invalid task range: " << part << std::endl;

      return;
    }

    const Int_t begin = first.Atoi();
    const Int_t end   = last.Atoi();

    if (begin > end) {
      std::cerr << "-E- " << myName << ": Invalid task range: " << part << " (start > end)" << std::endl;

      return;
    }

    for (Int_t id = begin; id <= end; ++id) {
      taskIds.push_back(id);
    }
  }


  // -------------------------------------------------------------------------
  // Validate parsed task list
  // -------------------------------------------------------------------------

  if (taskIds.empty()) {
    std::cerr << "-E- " << myName << ": No task IDs selected." << std::endl;

    return;
  }


  // -------------------------------------------------------------------------
  // Construct input filenames
  // -------------------------------------------------------------------------

  traFiles.reserve(taskIds.size());
  rawFiles.reserve(taskIds.size());
  recoFiles.reserve(taskIds.size());

  for (const Int_t id : taskIds) {

    add_qa_input(id, outputDir, traFiles, rawFiles, recoFiles);
  }


  // -------------------------------------------------------------------------
  // Parameter and output files
  // -------------------------------------------------------------------------

  const Int_t firstId = taskIds.front();

  const TString parFile = TString::Format("%s/rec/%d/%d.par.root", outputDir.Data(), firstId, firstId);

  const TString qaOutput = TString::Format("%s/qa/qa.root", outputDir.Data());


  // -------------------------------------------------------------------------
  // Validate all required input files
  // -------------------------------------------------------------------------

  std::cout << "\n-I- " << myName << ": Validating " << taskIds.size() << " input chunks" << std::endl;

  for (size_t i = 0; i < taskIds.size(); ++i) {

    if (gSystem->AccessPathName(traFiles[i].Data())) {

      std::cerr << "-E- " << myName << ": Missing transport file for task " << taskIds[i] << ":\n    " << traFiles[i]
                << std::endl;

      return;
    }

    if (gSystem->AccessPathName(rawFiles[i].Data())) {

      std::cerr << "-E- " << myName << ": Missing digitization file for task " << taskIds[i] << ":\n    " << rawFiles[i]
                << std::endl;

      return;
    }

    if (gSystem->AccessPathName(recoFiles[i].Data())) {

      std::cerr << "-E- " << myName << ": Missing reconstruction file for task " << taskIds[i] << ":\n    "
                << recoFiles[i] << std::endl;

      return;
    }
  }

  if (gSystem->AccessPathName(parFile.Data())) {

    std::cerr << "-E- " << myName << ": Missing parameter file:\n    " << parFile << std::endl;

    return;
  }


  // -------------------------------------------------------------------------
  // Summary
  // -------------------------------------------------------------------------

  std::cout << "\n-I- " << myName << ": Pipeline QA input" << '\n'
            << "    Output directory: " << outputDir << '\n'
            << "    Task range:       " << taskRange << '\n'
            << "    Input chunks:     " << taskIds.size() << '\n'
            << "    First task:       " << taskIds.front() << '\n'
            << "    Last task:        " << taskIds.back() << '\n'
            << "    Parameter file:   " << parFile << '\n'
            << "    QA output:        " << qaOutput << std::endl;


  // -------------------------------------------------------------------------
  // Forward to the vector-based QA implementation
  // -------------------------------------------------------------------------

  run_qa(traFiles, rawFiles, recoFiles, parFile, qaOutput, setup, nEvents, {}, {}, "", "Ideal", "");
}


// ---------------------------------------------------------------------------
// Original single-file interface
//
// This preserves the previous behaviour. A single set of input files is
// converted into vectors containing one element and forwarded to the
// vector-based implementation.
// ---------------------------------------------------------------------------

void run_qa(TString dataTraColl, TString dataRaw, TString dataReco, TString dataPar, TString dataSink,
            TString setup = "sis100_electron", Int_t nEvents = -1, TString dataTraSign = "", TString dataTraBeam = "",
            TString config = "", TString sEvBuildRaw = "Ideal", TString sBenchmark = "")
{
  std::vector<TString> traColl = {dataTraColl};
  std::vector<TString> raw     = {dataRaw};
  std::vector<TString> reco    = {dataReco};

  std::vector<TString> traSign;
  std::vector<TString> traBeam;

  if (!dataTraSign.IsNull()) {
    traSign.push_back(dataTraSign);
  }

  if (!dataTraBeam.IsNull()) {
    traBeam.push_back(dataTraBeam);
  }

  run_qa(traColl, raw, reco, dataPar, dataSink, setup, nEvents, traSign, traBeam, config, sEvBuildRaw, sBenchmark);
}


// ---------------------------------------------------------------------------
// Multi-file implementation
// ---------------------------------------------------------------------------

void run_qa(const std::vector<TString>& dataTraColl, const std::vector<TString>& dataRaw,
            const std::vector<TString>& dataReco, TString dataPar, TString dataSink, TString setup = "sis100_electron",
            Int_t nEvents = -1, const std::vector<TString>& dataTraSign = {},
            const std::vector<TString>& dataTraBeam = {}, TString config = "", TString sEvBuildRaw = "Ideal",
            TString sBenchmark = "")
{
  gROOT->SetBatch(kTRUE);

  FairLogger::GetLogger()->SetLogScreenLevel("INFO");

  fair::Logger::DefineVerbosity(
    "user1", fair::VerbositySpec::Make(fair::VerbositySpec::Info::severity, fair::VerbositySpec::Info::file_line));

  FairLogger::GetLogger()->SetLogVerbosityLevel("user1");
  FairLogger::GetLogger()->SetColoredLog(true);

  constexpr bool bUseMC = true;
  constexpr int verbose = 3;

  const TString myName = "run_qa";
  const TString srcDir = gSystem->Getenv("VMCWORKDIR");


  // -------------------------------------------------------------------------
  // Basic input validation
  // -------------------------------------------------------------------------

  if (dataRaw.empty()) {
    std::cerr << "-E- " << myName << ": No digitization input files provided." << std::endl;
    return;
  }

  if (dataTraColl.empty()) {
    std::cerr << "-E- " << myName << ": No transport input files provided." << std::endl;
    return;
  }

  if (dataReco.empty()) {
    std::cerr << "-E- " << myName << ": No reconstruction input files provided." << std::endl;
    return;
  }

  if (dataRaw.size() != dataTraColl.size() || dataRaw.size() != dataReco.size()) {

    std::cerr << "-E- " << myName << ": Input file lists have different sizes:\n"
              << "    transport:      " << dataTraColl.size() << '\n'
              << "    digitization:   " << dataRaw.size() << '\n'
              << "    reconstruction: " << dataReco.size() << std::endl;
    return;
  }

  std::cout << "\n-I- " << myName << ": Number of input chunks: " << dataRaw.size() << std::endl;


  // -------------------------------------------------------------------------
  // Setup
  // -------------------------------------------------------------------------

  std::cout << "\n-I- " << myName << ": Loading setup " << setup << std::endl;

  auto* geo = CbmSetup::Instance();

  geo->LoadSetup(setup);

  const ECbmRecoMode recoMode = !sEvBuildRaw.IsNull() ? ECbmRecoMode::EventByEvent : ECbmRecoMode::Timeslice;
  const bool bUseMvd          = geo->IsActive(ECbmModuleId::kMvd);
  const bool bUseSts          = geo->IsActive(ECbmModuleId::kSts);
  std::cout << "  MVD: " << (bUseMvd ? "ON" : "OFF") << '\n';
  std::cout << "  STS: " << (bUseSts ? "ON" : "OFF") << '\n';


  // -------------------------------------------------------------------------
  // Timer
  // -------------------------------------------------------------------------
  TStopwatch timer;
  timer.Start();
  gDebug = 0;

  // -------------------------------------------------------------------------
  // Input files
  // -------------------------------------------------------------------------
  auto* inputSource = new FairFileSource(dataRaw.at(0));
  // Add the remaining digitization files to the primary input chain.
  for (size_t i = 1; i < dataRaw.size(); ++i) {
    inputSource->AddFile(dataRaw[i]);
  }

  // Add transport files.
  for (const auto& file : dataTraColl) {
    inputSource->AddFriend(file);
  }

  // Add reconstruction files.
  for (const auto& file : dataReco) {
    inputSource->AddFriend(file);
  }

  // Optional signal transport files.
  for (const auto& file : dataTraSign) {
    inputSource->AddFriend(file);
  }

  // Optional beam transport files.
  for (const auto& file : dataTraBeam) {
    inputSource->AddFriend(file);
  }


  // -------------------------------------------------------------------------
  // FairRun
  // -------------------------------------------------------------------------
  auto* run = new FairRunAna();
  run->SetSource(inputSource);
  run->SetGenerateRunInfo(kFALSE);
  run->SetSink(new FairRootFileSink(dataSink));

  // -------------------------------------------------------------------------
  // Monitoring
  // -------------------------------------------------------------------------
  TString monitorFile            = dataSink;
  const Ssiz_t extensionPosition = monitorFile.Last('.');
  if (extensionPosition != kNPOS) {
    monitorFile.Insert(extensionPosition + 1, "monitor.");
  }

  FairMonitor::GetMonitor()->EnableMonitor(kTRUE, monitorFile);


  // -------------------------------------------------------------------------
  // QA manager
  // -------------------------------------------------------------------------
  auto* qaManager = new CbmQaManager(verbose);
  if (!sBenchmark.IsNull()) {
    qaManager->OpenBenchmarkInput(sBenchmark);
    qaManager->OpenBenchmarkOutput(dataSink);
    qaManager->SetDefaultTag("default");
    qaManager->SetVersionTag("this");
  }
  run->AddTask(qaManager);

  // -------------------------------------------------------------------------
  // MC manager
  // -------------------------------------------------------------------------
  auto* mcManager = new CbmMCDataManager("MCDataManager", 0);

  for (const auto& file : dataTraColl) {
    mcManager->AddFileToChain(file, 0);
  }

  for (const auto& file : dataTraSign) {
    mcManager->AddFileToChain(file, 1);
  }

  for (const auto& file : dataTraBeam) {
    mcManager->AddFileToChain(file, 2);
  }

  qaManager->AddTask(mcManager);


  // -------------------------------------------------------------------------
  // Reconstruction setup
  // -------------------------------------------------------------------------

  auto* recoSetupManager = cbm::RecoSetupManager::Instance();
  recoSetupManager->BuildGeoNodeMaps();
  qaManager->AddTask(recoSetupManager);

  // -------------------------------------------------------------------------
  // CA parameters
  // -------------------------------------------------------------------------

  auto& caParameters     = cbm::ca::ParametersHandler::Instance();
  const TString caConfig = srcDir + "/macro/L1/configs/ca_params_sts.yaml";
  caParameters.SetMainConfig(caConfig.Data());
  qaManager->AddTask(&caParameters);


  // -------------------------------------------------------------------------
  // MC matching
  // -------------------------------------------------------------------------
  if (bUseMC) {
    auto* matchTask = new CbmMatchRecoToMC();
    matchTask->SuppressHitReMatching();
    qaManager->AddTask(matchTask);
  }


  // -------------------------------------------------------------------------
  // KF
  // -------------------------------------------------------------------------

  qaManager->AddTask(new CbmKF());


  // -------------------------------------------------------------------------
  // CA output QA
  // -------------------------------------------------------------------------

  auto* outputQa = new cbm::ca::OutputQa(verbose, bUseMC, recoMode);

  outputQa->SetStsTrackingMode();

  outputQa->SetUseMvd(bUseMvd);

  outputQa->SetUseSts(bUseSts);

  qaManager->AddTask(outputQa);


  // -------------------------------------------------------------------------
  // Runtime DB
  // -------------------------------------------------------------------------

  std::cout << "\n\n-I- " << myName << ": Set runtime DB" << std::endl;

  auto* parameterInput = new FairParRootFileIo();

  parameterInput->open(dataPar.Data(), "in");

  FairRuntimeDb* runtimeDb = run->GetRuntimeDb();

  runtimeDb->setFirstInput(parameterInput);

  runtimeDb->print();


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

  const Double_t cpuTime = timer.CpuTime();

  std::cout << "\n\nMacro finished successfully.\n"
            << "Output file is " << dataSink << '\n'
            << "Parameter file is " << dataPar << '\n'
            << "Real time " << realTime << " s, CPU time " << cpuTime << " s\n\n"
            << " QA checks " << (qaManager->GetStatus() ? "\e[1;32mpassed" : "\e[1;31mfailed") << "\e[0m\n"
            << " Test passed\n All ok " << std::endl;

  FairSystemInfo systemInfo;

  std::cout << "<DartMeasurement "
            << "name=\"MaxMemory\" "
            << "type=\"numeric/double\">" << systemInfo.GetMaxMemory() << "</DartMeasurement>\n";

  std::cout << "<DartMeasurement "
            << "name=\"CpuLoad\" "
            << "type=\"numeric/double\">" << (realTime > 0. ? cpuTime / realTime : 0.) << "</DartMeasurement>"
            << std::endl;
}


// ---------------------------------------------------------------------------
// Original convenience interface
// ---------------------------------------------------------------------------

void run_qa(TString data = "test", TString setup = "sis100_electron", Int_t nEvents = -1, TString dataTra2 = "",
            TString dataTra3 = "", TString configName = "", TString sEvBuildRaw = "")
{
  run_qa(data, data, data, data, data, setup, nEvents, dataTra2, dataTra3, configName, sEvBuildRaw);
}
