const jwt = require('jsonwebtoken');
const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();

module.exports = async (req, res, next) => {
    try {
        const authHeader = req.headers.authorization;
        if (!authHeader) return res.status(401).json({ message: "No token" });

        const token = authHeader.split(' ')[1];
        const decoded = jwt.verify(token, process.env.JWT_SECRET);

        // 🔥 ПРОВЕРКА: Существует ли юзер в Postgres?
        const user = await prisma.user.findUnique({ where: { id: decoded.userId } });
        
        if (!user) {
            console.error("🚫 Token valid, but user DELETED from database.");
            return res.status(401).json({ message: "User no longer exists" });
        }

        req.user = decoded;
        next();
    } catch (e) {
        res.status(401).json({ message: "Invalid token" });
    }
};