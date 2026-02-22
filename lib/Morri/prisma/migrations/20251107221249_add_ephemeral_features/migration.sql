-- AlterTable
ALTER TABLE "ChatRoom" ADD COLUMN     "isEphemeral" BOOLEAN NOT NULL DEFAULT false;

-- AlterTable
ALTER TABLE "Message" ADD COLUMN     "expiresAt" TIMESTAMP(3);
