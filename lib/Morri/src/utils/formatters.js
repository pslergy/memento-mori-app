// src/utils/formatters.js

/**
 * Форматирует объект ChatRoom для отправки клиенту.
 * @param {object} chat - Объект ChatRoom из Prisma, включающий participants.user и messages.
 * @param {string} currentUserId - ID текущего пользователя.
 * @returns {object} - Стандартизированный объект чата.
 */
function formatChatForClient(chat, currentUserId) {
    const lastMessage = chat.messages?.[0];
    const otherParticipant = chat.participants?.find(p => p.userId !== currentUserId);

    return {
        id: chat.id,
        name: chat.name,
        type: chat.type,
        isEphemeral: chat.isEphemeral,
        lastMessage: lastMessage ? {
            id: lastMessage.id,
            content: lastMessage.content,
            createdAt: lastMessage.createdAt,
            senderId: lastMessage.senderId
        } : null,
        otherUser: otherParticipant ? {
            id: otherParticipant.user.id,
            username: otherParticipant.user.username,
        } : null // Для групп здесь будет другая логика
    };
}

module.exports = { formatChatForClient };