-- CreateTable
CREATE TABLE "EphemeralToken" (
    "token" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "EphemeralToken_pkey" PRIMARY KEY ("token")
);

-- CreateIndex
CREATE INDEX "EphemeralToken_expiresAt_idx" ON "EphemeralToken"("expiresAt");
