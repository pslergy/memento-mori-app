-- AlterTable: каналы — владелец, тип, закрытый; инвайт-ссылки
ALTER TABLE "ChatRoom" ADD COLUMN     "ownerId" TEXT,
ADD COLUMN     "channelType" TEXT,
ADD COLUMN     "isPrivate" BOOLEAN NOT NULL DEFAULT false;

-- CreateTable: токены приглашений в канал
CREATE TABLE "ChannelInvite" (
    "token" TEXT NOT NULL,
    "chatRoomId" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "expiresAt" TIMESTAMP(3),

    CONSTRAINT "ChannelInvite_pkey" PRIMARY KEY ("token")
);

CREATE INDEX "ChannelInvite_chatRoomId_idx" ON "ChannelInvite"("chatRoomId");

ALTER TABLE "ChannelInvite" ADD CONSTRAINT "ChannelInvite_chatRoomId_fkey" FOREIGN KEY ("chatRoomId") REFERENCES "ChatRoom"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "ChatRoom" ADD CONSTRAINT "ChatRoom_ownerId_fkey" FOREIGN KEY ("ownerId") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;
