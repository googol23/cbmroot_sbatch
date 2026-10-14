#if !defined(__CLING__)
#include "CbmCaOutputQa.h"
#include "CbmCaParametersHandler.h"
#include "CbmDefs.h"
#include "CbmKF.h"
#include "CbmMCDataManager.h"
#include "CbmMatchRecoToMC.h"
#include "CbmQaManager.h"
#include "CbmRecoSetupManager.h"
#include "CbmSetup.h"

#include <FairFileSource.h>
#include <FairParRootFileIo.h>
#include <FairRootFileSink.h>
#include <FairRunAna.h>
#include <FairRuntimeDb.h>

#include <TString.h>
#include <TSystem.h>

#include <iostream>
#endif

void run_rec_qa(TString traFile, TString rawFile, TString recoFile, TString parFile,
                TString setup = "sis100_electron", Int_t nEvents = -1,
                TString sinkFile = "test.reco.qa.root")
{
  constexpr Int_t verbose = 3;

  auto* geo = CbmSetup::Instance();
  geo->LoadSetup(setup);

  auto* source = new FairFileSource(rawFile);
  source->AddFriend(traFile);
  source->AddFriend(recoFile);

  auto* run = new FairRunAna();
  run->SetSource(source);
  run->SetGenerateRunInfo(kFALSE);
  run->SetSink(new FairRootFileSink(sinkFile));

  auto* qaManager = new CbmQaManager(verbose);
  run->AddTask(qaManager);

  auto* mcManager = new CbmMCDataManager("MCDataManager", 0);
  mcManager->AddFileToChain(traFile, 0);
  qaManager->AddTask(mcManager);

  auto* recoSetupManager = cbm::RecoSetupManager::Instance();
  recoSetupManager->BuildGeoNodeMaps();
  qaManager->AddTask(recoSetupManager);

  auto& caParameters = cbm::ca::ParametersHandler::Instance();
  const TString caConfig = TString(gSystem->Getenv("VMCWORKDIR")) + "/macro/L1/configs/ca_params_sts.yaml";
  caParameters.SetMainConfig(caConfig.Data());
  qaManager->AddTask(&caParameters);

  auto* matchTask = new CbmMatchRecoToMC();
  matchTask->SuppressHitReMatching();
  qaManager->AddTask(matchTask);
  qaManager->AddTask(new CbmKF());

  auto* outputQa = new cbm::ca::OutputQa(verbose, true, ECbmRecoMode::EventByEvent);
  outputQa->SetStsTrackingMode();
  outputQa->SetUseMvd(geo->IsActive(ECbmModuleId::kMvd));
  outputQa->SetUseSts(geo->IsActive(ECbmModuleId::kSts));
  qaManager->AddTask(outputQa);

  auto* parameterInput = new FairParRootFileIo();
  parameterInput->open(parFile.Data(), "in");
  FairRuntimeDb* runtimeDb = run->GetRuntimeDb();
  runtimeDb->setFirstInput(parameterInput);

  run->Init();
  run->Run(0, nEvents);

  std::cout << "Macro finished successfully.\n"
            << "Output file is " << sinkFile << std::endl;
}
