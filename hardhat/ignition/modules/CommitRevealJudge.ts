import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const CommitRevealJudgeModule = buildModule("CommitRevealJudgeModule", (m) => {
  const judge = m.contract("CommitRevealJudge", []);
  return { judge };
});

export default CommitRevealJudgeModule;
