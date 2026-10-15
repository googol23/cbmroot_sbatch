void run_tra_qa(TString traFile = "/lustre/cbm/users/dramirez/mc/out/test/tra/1/1.tra.root",
                TString parFile = "/lustre/cbm/users/dramirez/mc/out/test/tra/1/1.par.root",
                Int_t nEvents = -1,
                TString sinkFile = "/lustre/cbm/users/dramirez/mc/out/test/qa/1/1.tra.qa.root")
{

  Int_t verbose = 1;

  // -----   FairRunAna   ---------------------------------------------------
  FairFileSource* inputSource = new FairFileSource(traFile);

  FairRunAna* run = new FairRunAna();
  run->SetSource(inputSource);
  run->SetGenerateRunInfo(kFALSE);

  FairRootFileSink* sink = new FairRootFileSink(sinkFile);
  run->SetSink(sink);

  auto* qaManager = new CbmQaManager(verbose);
  run->AddTask(qaManager);
  // ------------------------------------------------------------------------

  // -----   QA task   -------------------------------------------------------
  qaManager->AddTask(new cbm::qa::CbmStsTransportQa(verbose, /*isMCUsed*/ kTRUE));
  // ------------------------------------------------------------------------

  // -----   Parameter database (optional; not needed by the task below)   ---
  // Not used by TransportTask (it requests no FairParSet), kept as the hook point for a real QA
  // task that does need one (e.g. geometry-dependent QA).
  if (!parFile.IsNull()) {
    FairRuntimeDb* rtdb       = run->GetRuntimeDb();
    FairParRootFileIo* parIo1 = new FairParRootFileIo();
    parIo1->open(parFile.Data(), "in");
    rtdb->setFirstInput(parIo1);
  }
  // ------------------------------------------------------------------------

  // -----   Run   ------------------------------------------------------------
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
