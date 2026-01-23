import 'package:flutter/material.dart';
import '../core/room_service.dart';
import '../core/room_events.dart';

/// Dev tool for debugging room events
/// Simple timeline viewer with filtering
/// 
/// NOT for production users.
/// For debugging after 3 months.
class RoomTimelineDebugger extends StatefulWidget {
  final String roomId;
  
  const RoomTimelineDebugger({
    super.key,
    required this.roomId,
  });

  @override
  State<RoomTimelineDebugger> createState() => _RoomTimelineDebuggerState();
}

class _RoomTimelineDebuggerState extends State<RoomTimelineDebugger> {
  final RoomService _roomService = RoomService();
  List<RoomEvent> _events = [];
  EventOrigin? _filterOrigin;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadEvents();
  }

  Future<void> _loadEvents() async {
    setState(() => _isLoading = true);
    try {
      final events = await _roomService.getRoomEvents(widget.roomId);
      setState(() {
        _events = events;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  List<RoomEvent> get _filteredEvents {
    var filtered = List<RoomEvent>.from(_events);
    
    // Sort by time
    filtered.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    // Filter by origin
    if (_filterOrigin != null) {
      filtered = filtered.where((e) => e.origin == _filterOrigin).toList();
    }
    
    return filtered;
  }

  String _getOriginColor(EventOrigin origin) {
    switch (origin) {
      case EventOrigin.LOCAL:
        return '#00FF00'; // Green
      case EventOrigin.MESH:
        return '#00FFFF'; // Cyan
      case EventOrigin.SERVER:
        return '#FF00FF'; // Magenta
    }
  }

  String _getOriginIcon(EventOrigin origin) {
    switch (origin) {
      case EventOrigin.LOCAL:
        return '📱';
      case EventOrigin.MESH:
        return '📡';
      case EventOrigin.SERVER:
        return '☁️';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        title: const Text(
          'Room Timeline Debugger',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadEvents,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter bar
          Container(
            padding: const EdgeInsets.all(8),
            color: const Color(0xFF1A1A1A),
            child: Row(
              children: [
                const Text(
                  'Filter:',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(width: 8),
                _buildFilterChip('All', null),
                const SizedBox(width: 4),
                _buildFilterChip('LOCAL', EventOrigin.LOCAL),
                const SizedBox(width: 4),
                _buildFilterChip('MESH', EventOrigin.MESH),
                const SizedBox(width: 4),
                _buildFilterChip('SERVER', EventOrigin.SERVER),
              ],
            ),
          ),
          
          // Event count
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF1A1A1A),
            child: Row(
              children: [
                Text(
                  'Events: ${_filteredEvents.length} / ${_events.length}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          
          // Timeline
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredEvents.isEmpty
                    ? const Center(
                        child: Text(
                          'No events',
                          style: TextStyle(color: Colors.white38),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: _filteredEvents.length,
                        itemBuilder: (context, index) {
                          final event = _filteredEvents[index];
                          final isLast = index == _filteredEvents.length - 1;
                          
                          return _buildTimelineItem(event, isLast);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, EventOrigin? origin) {
    final isSelected = _filterOrigin == origin;
    return GestureDetector(
      onTap: () {
        setState(() => _filterOrigin = origin);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.cyanAccent : const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? Colors.cyanAccent : Colors.white24,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.white70,
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildTimelineItem(RoomEvent event, bool isLast) {
    final originColor = _getOriginColor(event.origin);
    final originIcon = _getOriginIcon(event.origin);
    
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Timeline line
        Column(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Color(int.parse(originColor.substring(1), radix: 16) + 0xFF000000),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: Center(
                child: Text(
                  originIcon,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            if (!isLast)
              Container(
                width: 2,
                height: 60,
                color: Colors.white24,
              ),
          ],
        ),
        const SizedBox(width: 12),
        
        // Event card
        Expanded(
          child: Card(
            color: const Color(0xFF1A1A1A),
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header: type + origin
                  Row(
                    children: [
                      Text(
                        event.type,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Color(int.parse(originColor.substring(1), radix: 16) + 0xFF000000).withOpacity(0.3),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          event.origin.name,
                          style: TextStyle(
                            color: Color(int.parse(originColor.substring(1), radix: 16) + 0xFF000000),
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  
                  // User ID
                  Text(
                    'User: ${event.userId.substring(0, 8)}...',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 4),
                  
                  // Timestamp
                  Text(
                    _formatTimestamp(event.timestamp),
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                    ),
                  ),
                  
                  // Event ID
                  Text(
                    'ID: ${event.id.substring(0, 8)}...',
                    style: const TextStyle(
                      color: Colors.white24,
                      fontSize: 9,
                    ),
                  ),
                  
                  // Payload (if exists)
                  if (event.payload != null && event.payload!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _formatPayload(event.payload!),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final diff = now.difference(timestamp);
    
    if (diff.inSeconds < 60) {
      return '${diff.inSeconds}s ago';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else {
      return '${diff.inDays}d ago';
    }
  }

  String _formatPayload(Map<String, dynamic> payload) {
    final buffer = StringBuffer();
    payload.forEach((key, value) {
      buffer.writeln('$key: $value');
    });
    return buffer.toString().trim();
  }
}
