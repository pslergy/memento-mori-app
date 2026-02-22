-- AlterEnum
ALTER TYPE "ChatType" ADD VALUE 'GLOBAL';

-- AlterTable
ALTER TABLE "ChatRoom" ADD COLUMN     "description" TEXT,
ADD COLUMN     "isPublic" BOOLEAN NOT NULL DEFAULT false;
