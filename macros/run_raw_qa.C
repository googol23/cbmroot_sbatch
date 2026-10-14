void run_raw_qa(TString rawFile, TString traFile = "", Int_t nEvents = -1,
                TString sinkFile = "test.raw.qa.root")
{
  Int_t verbose = 1;
  Bool_t useMc  = !traFile.IsNull();

  // -----   FairRunAna   ---------------------------------------------------
  FairFileSource* inputSource = new FairFileSource(rawFile);
  if (useMc) inputSource->AddFriend(traFile);

  FairRunAna* run = new FairRunAna();
  run->SetSource(inputSource);
  run->SetGenerateRunInfo(kFALSE);

  FairRootFileSink* sink = new FairRootFileSink(sinkFile);
  run->SetSink(sink);

  auto* qaManager = new CbmQaManager(verbose);
  run->AddTask(qaManager);
  // ------------------------------------------------------------------------

  // -----   Optional MC data   ---------------------------------------------
  if (useMc) {
    auto* mcManager = new CbmMCDataManager("MCDataManager", 0);
    mcManager->AddFileToChain(traFile, 0);
    qaManager->AddTask(mcManager);
  }
  // ------------------------------------------------------------------------

  // -----   QA task   -------------------------------------------------------
  qaManager->AddTask(new cbm::qa::CbmStsDigiQa(verbose, useMc, 0, 1., std::nullopt));
  // ------------------------------------------------------------------------

  // -----   Run   -----------------------------------------------------------
  run->Init();
  run->Run(0, nEvents);
  // ------------------------------------------------------------------------

  std::cout << std::endl;
  std::cout << "Macro finished. Output file is " << sinkFile << std::endl;
  std::cout << " QA checks " << (qaManager->GetStatus() ? "\e[1;32mpassed" : "\e[1;31mfailed") << "\e[0m\n";

  // Same TGeoManager double-free workaround as macro/include/rootalias.C::RemoveGeoManager(),
  if (gGeoManager && gROOT->GetVersionInt() >= 60602) {
    gGeoManager->GetListOfVolumes()->Delete();
    gGeoManager->GetListOfShapes()->Delete();
    delete gGeoManager;
  }
}
