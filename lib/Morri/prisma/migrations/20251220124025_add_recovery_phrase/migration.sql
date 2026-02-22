-- AlterTable
ALTER TABLE "User" ADD COLUMN     "isShadow" BOOLEAN NOT NULL DEFAULT false,
ADD COLUMN     "recoveryMnemonicHash" TEXT;
