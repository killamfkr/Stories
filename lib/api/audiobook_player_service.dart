import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:audio_service/audio_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'audiobook_service.dart';
import 'android_auto_ids.dart';
import 'audiobook_prefs_keys.dart';
import 'audio_handler.dart';
import 'torrent_stream_service.dart';
import '../services/playtorrio_cloud_sync_service.dart';
import 'settings_service.dart';

class AudiobookPlayerService {
  static final AudiobookPlayerService _instance = AudiobookPlayerService._internal();
  factory AudiobookPlayerService() => _instance;
  AudiobookPlayerService._internal();

  /// Headers for libtorrent's loopback HTTP stream (mpv is picky without these).
  static const Map<String, String> magnetStreamHttpHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'Accept': '*/*',
  };

  final Player _player = Player();
  PlayTorrioAudioHandler? _handler;
  
  // State
  final ValueNotifier<Audiobook?> currentBook = ValueNotifier<Audiobook?>(null);
  final ValueNotifier<int> currentChapterIndex = ValueNotifier<int>(0);
  final ValueNotifier<Duration> position = ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<Duration> duration = ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<bool> isPlaying = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isBuffering = ValueNotifier<bool>(false);
  /// True while a chapter is opening/buffering — UI should show loading, not pause.
  final ValueNotifier<bool> isPreparingPlayback = ValueNotifier<bool>(false);
  final ValueNotifier<bool> autoplay = ValueNotifier<bool>(true);
  
  List<AudiobookChapter> _currentChapters = [];
  final List<StreamSubscription> _subscriptions = [];
  bool _playerListenersAttached = false;
  bool _mpvAudiobookTuned = false;
  Timer? _progressTicker;
  bool _isResuming = false;
  Timer? _progressSaveDebounce;
  /// Wall-clock fallback when torrent loopback streams report position 0.
  Duration _wallClockBase = Duration.zero;
  DateTime? _wallClockStartedAt;
  /// Ignore position-driven persistence briefly after resume/chapter opens — mpv often
  /// emits 0 before the clock catches up and would overwrite real progress.
  DateTime? _ignoreProgressPersistenceUntil;
  /// While non-null, ignore player clock readings that snap back to the start.
  Duration? _resumeTargetPosition;
  /// Torrent loopback URLs often never report a trustworthy position.
  bool _streamClockUnreliable = false;
  /// Lowest position we know the user has reached this chapter — never snap UI/audio below it.
  int _positionFloorMs = 0;
  DateTime? _lastCorrectiveSeekAt;

  void _raisePositionFloor(Duration resolved) {
    final ms = resolved.inMilliseconds;
    if (ms > _positionFloorMs) _positionFloorMs = ms;
  }

  void _maybeCorrectiveSeek() {
    if (_positionFloorMs < 5000 || !isPlaying.value) return;
    final now = DateTime.now();
    if (_lastCorrectiveSeekAt != null &&
        now.difference(_lastCorrectiveSeekAt!) < const Duration(seconds: 2)) {
      return;
    }
    final target = Duration(milliseconds: _positionFloorMs);
    final playerPos = _player.state.position;
    if (playerPos >= target - const Duration(seconds: 6)) return;
    _lastCorrectiveSeekAt = now;
    debugPrint(
      'AudiobookPlayerService: corrective seek to ${target.inSeconds}s '
      '(player at ${playerPos.inSeconds}s)',
    );
    unawaited(_player.seek(target));
  }

  bool _acceptPlayerPosition(Duration playerPosition) {
    if (_positionFloorMs > 8000 &&
        playerPosition.inMilliseconds < _positionFloorMs - 5000) {
      _maybeCorrectiveSeek();
      return false;
    }

    final target = _resumeTargetPosition;
    final until = _ignoreProgressPersistenceUntil;
    final inSettleWindow =
        until != null && DateTime.now().isBefore(until);

    if (inSettleWindow &&
        playerPosition < const Duration(seconds: 2) &&
        _wallClockBase > const Duration(seconds: 5)) {
      return false;
    }

    if (target != null && target > const Duration(seconds: 3)) {
      if (playerPosition < const Duration(seconds: 2)) {
        return false;
      }
      final delta = (playerPosition - target).abs();
      if (delta > const Duration(seconds: 8) &&
          playerPosition < target - const Duration(seconds: 8)) {
        return false;
      }
    }
    return true;
  }

  void _applyResolvedPosition(Duration resolved) {
    position.value = resolved;
    _wallClockBase = resolved;
    _raisePositionFloor(resolved);
    if (isPlaying.value) {
      _markWallClock(base: resolved);
    }
  }

  bool get _mayPersistPlaybackProgress {
    if (_isResuming) return false;
    final until = _ignoreProgressPersistenceUntil;
    if (until != null && DateTime.now().isBefore(until)) return false;
    return currentBook.value != null;
  }

  void _scheduleDebouncedProgressSave() {
    if (!_mayPersistPlaybackProgress) return;
    _progressSaveDebounce?.cancel();
    _progressSaveDebounce = Timer(const Duration(milliseconds: 900), () {
      _progressSaveDebounce = null;
      if (_mayPersistPlaybackProgress) {
        unawaited(_saveProgress());
      }
    });
  }

  void init(BaseAudioHandler handler) {
    attachHandler(handler);
    ensurePlayerListeners();
  }

  void attachHandler(BaseAudioHandler handler) {
    _handler = handler as PlayTorrioAudioHandler;
  }

  PlayTorrioAudioHandler? get audioHandler => _handler;

  List<AudiobookChapter> get currentChapters =>
      List<AudiobookChapter>.unmodifiable(_currentChapters);

  int get currentChapterCount => _currentChapters.length;

  /// Attaches media_kit listeners. Safe to call even when [AudioService] failed.
  void ensurePlayerListeners() {
    if (_playerListenersAttached) return;
    _playerListenersAttached = true;

    _subscriptions.add(_player.stream.position.listen((p) {
      if (isPreparingPlayback.value) return;
      if (!_acceptPlayerPosition(p)) return;
      if (_streamClockUnreliable && isPlaying.value) {
        if (p > position.value + const Duration(seconds: 1)) {
          position.value = p;
          _wallClockBase = p;
          _raisePositionFloor(p);
          _markWallClock(base: p);
          _updateSystemState();
          _scheduleDebouncedProgressSave();
        }
        return;
      }
      position.value = p;
      _wallClockBase = p;
      _raisePositionFloor(p);
      _updateSystemState();
      _scheduleDebouncedProgressSave();
    }));

    _subscriptions.add(_player.stream.duration.listen((d) {
      if (isPreparingPlayback.value && d <= Duration.zero) return;
      if (d > Duration.zero) {
        duration.value = d;
        _syncMediaItem();
      }
      _updateSystemState();
    }));

    _subscriptions.add(_player.stream.playing.listen((pl) {
      if (isPreparingPlayback.value) return;
      final wasPlaying = isPlaying.value;
      isPlaying.value = pl;
      if (pl) {
        if (_wallClockStartedAt == null) {
          _markWallClock(base: _wallClockBase);
        }
        _startProgressTicker();
      } else {
        _stopProgressTicker();
      }
      _updateSystemState();
      if (wasPlaying && !pl && !_isResuming && currentBook.value != null) {
        unawaited(_saveProgress(force: true));
      }
    }));

    _subscriptions.add(_player.stream.buffering.listen((b) {
      isBuffering.value = b;
      if (isPlaying.value && _wallClockStartedAt == null) {
        _markWallClock(base: _wallClockBase);
      }
      _updateSystemState();
    }));

    _subscriptions.add(_player.stream.completed.listen((completed) {
      if (completed && autoplay.value) {
        final nextIdx = currentChapterIndex.value + 1;
        if (nextIdx < _currentChapters.length) {
          unawaited(changeChapter(nextIdx));
        }
      }
    }));

    // Ticker starts when playback begins, not at app launch.
  }

  void _resetPlaybackUiState() {
    position.value = Duration.zero;
    duration.value = Duration.zero;
    isPlaying.value = false;
    isBuffering.value = true;
    isPreparingPlayback.value = true;
    _resetWallClock();
    _stopProgressTicker();
  }

  void _finishPreparingPlayback({Duration? positionHint}) {
    isPreparingPlayback.value = false;
    final st = _player.state;
    if (st.duration > Duration.zero) {
      duration.value = st.duration;
    }
    if (positionHint != null && positionHint > Duration.zero) {
      final playerPos = st.position;
      final resolved = playerPos > Duration.zero &&
              (playerPos - positionHint).abs() < const Duration(seconds: 8)
          ? playerPos
          : positionHint;
      _applyResolvedPosition(resolved);
    } else if (st.position > Duration.zero && _acceptPlayerPosition(st.position)) {
      _applyResolvedPosition(st.position);
    }
    isPlaying.value = st.playing;
    isBuffering.value = st.buffering;
    if (isPlaying.value) {
      if (_wallClockStartedAt == null) {
        _markWallClock(base: _wallClockBase);
      }
      _startProgressTicker();
    }
    _updateSystemState();
  }

  /// Torrent loopback streams often report duration/position late — wait briefly.
  Future<void> _waitForPlaybackClock({
    Duration timeout = const Duration(seconds: 5),
    Duration minPrepare = const Duration(milliseconds: 200),
  }) async {
    final deadline = DateTime.now().add(timeout);
    final minDone = DateTime.now().add(minPrepare);
    while (DateTime.now().isBefore(deadline)) {
      final st = _player.state;
      if (st.duration > Duration.zero) {
        duration.value = st.duration;
      }
      if (st.position > Duration.zero && _acceptPlayerPosition(st.position)) {
        position.value = st.position;
        _wallClockBase = st.position;
        _raisePositionFloor(st.position);
        return;
      }
      if (st.duration > Duration.zero && DateTime.now().isAfter(minDone)) {
        return;
      }
      if (st.playing && DateTime.now().isAfter(minDone)) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 60));
    }
  }

  /// After play() on a stream, wait until duration/position is available before seeking.
  Future<void> _waitForResumeReady(Audiobook book, AudiobookChapter chapter) async {
    final torrentResume = (book.source == 'magnet' ||
            book.source == 'audiobookbay') &&
        book.magnetLink != null &&
        book.magnetLink!.trim().isNotEmpty &&
        chapter.torrentFileIndex != null;
    if (torrentResume) {
      await _waitForStreamPrime();
      return;
    }

    final ready = Completer<void>();
    late StreamSubscription<Duration> durSub;
    durSub = _player.stream.duration.listen((d) {
      if (d > Duration.zero && !ready.isCompleted) {
        ready.complete();
      }
    });
    await ready.future.timeout(const Duration(seconds: 12), onTimeout: () {});
    await durSub.cancel();
  }

  /// Seek repeatedly until mpv settles near [target] (loopback streams often snap to 0).
  Future<void> _settleResumePosition(Duration target) async {
    _resumeTargetPosition = target;
    _ignoreProgressPersistenceUntil =
        DateTime.now().add(const Duration(seconds: 20));

    for (var attempt = 0; attempt < 12; attempt++) {
      if (attempt == 4) {
        await _player.pause();
        await Future.delayed(const Duration(milliseconds: 200));
      }
      await _player.seek(target);
      if (attempt == 4) {
        await _player.play();
      }
      await Future.delayed(Duration(milliseconds: 500 + attempt * 130));
      final p = _player.state.position;
      final delta = (p - target).abs();
      if (p > Duration.zero &&
          (delta < const Duration(seconds: 4) ||
              p >= target - const Duration(seconds: 2))) {
        debugPrint(
          'AudiobookPlayerService: resume seek settled ~${p.inSeconds}s '
          '(target ${target.inSeconds}s, attempt ${attempt + 1})',
        );
        _applyResolvedPosition(p);
        _resumeTargetPosition = null;
        return;
      }
    }

    debugPrint(
      'AudiobookPlayerService: resume seek may be inaccurate (target '
      '${target.inSeconds}s, got ${_player.state.position.inSeconds}s) — retrying paused seek',
    );
    await _player.pause();
    await _player.seek(target);
    await Future.delayed(const Duration(milliseconds: 900));
    await _player.play();
    await Future.delayed(const Duration(milliseconds: 700));
    final retried = _player.state.position;
    if (retried > Duration.zero) {
      _applyResolvedPosition(retried);
    } else {
      _applyResolvedPosition(target);
    }
    _resumeTargetPosition = null;
  }

  /// After play() on a torrent stream, wait until the loopback URL is primed.
  Future<void> _waitForStreamPrime({
    Duration minWait = const Duration(milliseconds: 150),
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (minWait > Duration.zero) {
      await Future.delayed(minWait);
    }
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final st = _player.state;
      if (st.position > Duration.zero || st.duration > Duration.zero) return;
      if (st.playing && !st.buffering) return;
      await Future.delayed(const Duration(milliseconds: 80));
    }
  }

  Future<void> _ensureMpvAudiobookTuning({required bool torrentBacked}) async {
    if (_mpvAudiobookTuned) return;
    if (_player.platform is! NativePlayer) return;
    final p = _player.platform as NativePlayer;
    await p.setProperty('hr-seek', 'yes');
    await p.setProperty('cache', 'yes');
    await p.setProperty('demuxer-max-bytes', '50000000');
    await p.setProperty('demuxer-max-back-bytes', '50000000');
    await p.setProperty('demuxer-readahead-secs', torrentBacked ? '12' : '30');
    if (torrentBacked) {
      await p.setProperty('force-seekable', 'yes');
      try {
        await p.setProperty('demuxer-seekable-cache', 'yes');
      } catch (_) {}
    }
    _mpvAudiobookTuned = true;
  }

  void _startProgressTicker() {
    _progressTicker ??= Timer.periodic(const Duration(milliseconds: 400), (_) {
      _pollPlayerClock();
    });
  }

  void _stopProgressTicker() {
    if (!isPlaying.value) {
      _progressTicker?.cancel();
      _progressTicker = null;
    }
  }

  void _markWallClock({Duration base = Duration.zero}) {
    _wallClockBase = base;
    _wallClockStartedAt = DateTime.now();
  }

  void _resetWallClock({Duration base = Duration.zero}) {
    _wallClockBase = base;
    _wallClockStartedAt = null;
  }

  /// Torrent loopback streams often skip stream events; poll [Player.state] directly.
  void _pollPlayerClock() {
    if (isPreparingPlayback.value) return;
    final st = _player.state;
    final p = st.position;
    final d = st.duration;
    var changed = false;

    if (p > Duration.zero) {
      if (_acceptPlayerPosition(p) && p != position.value) {
        position.value = p;
        _wallClockBase = p;
        changed = true;
      }
    } else if (isPlaying.value && _wallClockStartedAt != null) {
      var wall =
          _wallClockBase + DateTime.now().difference(_wallClockStartedAt!);
      if (d > Duration.zero && wall > d) wall = d;
      if (wall > position.value || _streamClockUnreliable) {
        position.value = wall;
        changed = true;
      }
    }
    if (d > Duration.zero && d != duration.value) {
      duration.value = d;
      changed = true;
      _syncMediaItem();
    }

    if (changed) {
      _updateSystemState();
      _scheduleDebouncedProgressSave();
    }
  }

  void _syncMediaItem() {
    final book = currentBook.value;
    final handler = _handler;
    if (book == null || handler == null) return;

    final idx = currentChapterIndex.value;
    final chapters = _currentChapters;
    final chapterTitle = (idx >= 0 && idx < chapters.length)
        ? chapters[idx].title
        : '';

    String artist = 'Tokybook';
    if (book.source == 'audiozaic') artist = 'Audiozaic';
    if (book.source == 'goldenaudiobook') artist = 'GoldenAudiobook';
    if (book.source == 'appaudiobooks') artist = 'AppAudiobooks';
    if (book.source == 'magnet') artist = 'Torrent';
    if (book.source == 'audiobookbay') artist = 'Audiobook Bay';

    String art = book.thumbUrl.trim();
    if (art.isEmpty) art = book.coverImage.trim();

    final dur = duration.value;
    unawaited(handler.updateMediaItem(MediaItem(
      id: book.audioBookId,
      album: book.title,
      title: chapterTitle.isEmpty ? book.title : chapterTitle,
      artist: artist,
      duration: dur > Duration.zero ? dur : null,
      artUri: art.isEmpty ? null : Uri.tryParse(art),
    )));
  }

  void _updateSystemState() {
    if (_handler == null || currentBook.value == null) return;
    
    _handler!.updateState(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        isPlaying.value ? MediaControl.pause : MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.playPause,
        MediaAction.stop,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: isBuffering.value ? AudioProcessingState.buffering : AudioProcessingState.ready,
      playing: isPlaying.value,
      updatePosition: position.value,
      bufferedPosition: _player.state.buffer,
      speed: _player.state.rate,
      queueIndex: currentChapterIndex.value,
    ));
  }

  Future<void> loadBook(Audiobook book, List<AudiobookChapter> chapters, {int initialChapter = 0, Duration? resumePosition}) async {
    final chapterCount = chapters.length;
    final idx = chapterCount == 0
        ? 0
        : initialChapter.clamp(0, chapterCount - 1);
    if (idx != initialChapter) {
      debugPrint(
        'AudiobookPlayerService: chapter index $initialChapter out of range '
        '($chapterCount chapters) — using $idx',
      );
    }

    _isResuming = initialChapter > 0 ||
        (resumePosition != null && resumePosition > Duration.zero);
    _resumeTargetPosition = null;
    _streamClockUnreliable = false;
    _positionFloorMs = 0;
    _lastCorrectiveSeekAt = null;
    _resetPlaybackUiState();
    _wallClockBase =
        _isResuming && resumePosition != null ? resumePosition : Duration.zero;

    currentBook.value = book;
    _currentChapters = chapters;
    currentChapterIndex.value = idx;
    _resetWallClock(base: _wallClockBase);

    if (!_isResuming) {
      _ignoreProgressPersistenceUntil =
          DateTime.now().add(const Duration(seconds: 2));
    } else if (resumePosition != null && resumePosition > Duration.zero) {
      position.value = resumePosition;
      _positionFloorMs = resumePosition.inMilliseconds;
    }

    _handler?.setPlayerType(AudioPlayerType.audiobook, _player);

    final chapterTitle = (idx >= 0 && idx < chapters.length)
        ? chapters[idx].title
        : '';

    String artist = 'Tokybook';
    if (book.source == 'audiozaic') artist = 'Audiozaic';
    if (book.source == 'goldenaudiobook') artist = 'GoldenAudiobook';
    if (book.source == 'appaudiobooks') artist = 'AppAudiobooks';
    if (book.source == 'magnet') artist = 'Torrent';
    if (book.source == 'audiobookbay') artist = 'Audiobook Bay';

    String art = book.thumbUrl.trim();
    if (art.isEmpty) art = book.coverImage.trim();

    _handler?.updateMediaItem(MediaItem(
      id: book.audioBookId,
      album: book.title,
      title: chapterTitle.isEmpty ? book.title : chapterTitle,
      artist: artist,
      duration: duration.value > Duration.zero ? duration.value : null,
      artUri: art.isEmpty ? null : Uri.tryParse(art),
    ));

    _syncChapterQueue();

    // Optimize for streaming audiobooks (once per player).
    final torrentBacked = book.source == 'magnet' || book.source == 'audiobookbay';
    if (torrentBacked) {
      _streamClockUnreliable = true;
    }
    await _ensureMpvAudiobookTuning(torrentBacked: torrentBacked);

    final needsSeek =
        resumePosition != null && resumePosition > Duration.zero;
    if (needsSeek) {
      _streamClockUnreliable = true;
    }
    final media = await _mediaForChapter(book, chapters[idx]);

    if (needsSeek &&
        resumePosition != null &&
        _player.platform is NativePlayer) {
      final native = _player.platform as NativePlayer;
      try {
        await native.setProperty('start', '${resumePosition.inSeconds}');
      } catch (_) {}
    }

    // Always open from the start; resume offset is applied via seek once buffered.
    await _player.open(media, play: false);

    var resumeAlreadyPlaying = false;
    Duration? preparingPositionHint;

    if (needsSeek) {
      debugPrint(
        'AudiobookPlayerService: Resuming chapter $idx at $resumePosition',
      );
      await _player.play();
      resumeAlreadyPlaying = true;
      await _waitForResumeReady(book, chapters[idx]);
      await _settleResumePosition(resumePosition!);
      preparingPositionHint = position.value > Duration.zero
          ? position.value
          : resumePosition;
    }

    if (!resumeAlreadyPlaying) {
      await _player.play();
    }

    await _waitForPlaybackClock();
    _isResuming = false;
    _finishPreparingPlayback(positionHint: preparingPositionHint);
  }

  Future<Media> _mediaForChapter(
    Audiobook book,
    AudiobookChapter ch,
  ) async {
    final magnet = book.magnetLink;
    final torrentBacked = (book.source == 'magnet' || book.source == 'audiobookbay') &&
        magnet != null &&
        magnet.isNotEmpty &&
        ch.torrentFileIndex != null;
    if (!torrentBacked) {
      final headers = ch.headers ?? const <String, String>{};
      return Media(
        ch.url,
        httpHeaders: headers,
      );
    }

    final torrent = TorrentStreamService();
    final started = await torrent.start();
    if (!started) {
      throw Exception('Torrent engine failed to start');
    }
    torrent.stopAudiobookStreamsForMagnet(magnet);
    final url = await torrent.streamAudiobookFile(
      magnet,
      ch.torrentFileIndex!,
      allowNonStreamable: true,
      stopSiblingStreams: false,
      fileNameHint: ch.title,
    );
    if (url == null || url.isEmpty) {
      throw Exception('Could not stream torrent file: ${ch.title}');
    }
    final merged = Map<String, String>.from(magnetStreamHttpHeaders);
    if (ch.headers != null) {
      merged.addAll(ch.headers!);
    }
    return Media(url, httpHeaders: merged);
  }

  void playOrPause() {
    if (isPreparingPlayback.value) {
      isPreparingPlayback.value = false;
      final st = _player.state;
      isPlaying.value = st.playing;
      isBuffering.value = st.buffering;
    }
    _player.playOrPause();
  }
  void seek(Duration p) => _player.seek(p);
  void setRate(double r) => _player.setRate(r);

  void skipToNextChapter() {
    final nextIdx = currentChapterIndex.value + 1;
    if (nextIdx < _currentChapters.length) {
      unawaited(changeChapter(nextIdx));
    }
  }

  void skipToPreviousChapter() {
    final prevIdx = currentChapterIndex.value - 1;
    if (prevIdx >= 0) {
      unawaited(changeChapter(prevIdx));
    }
  }

  Future<void> stop() async {
    await _player.stop();
    _updateSystemState();
  }

  Future<void> changeChapter(int index) async {
    if (index < 0 || index >= _currentChapters.length) return;
    currentChapterIndex.value = index;
    final book = currentBook.value;
    if (book == null) return;
    _positionFloorMs = 0;
    _resumeTargetPosition = null;
    _lastCorrectiveSeekAt = null;
    _resetPlaybackUiState();
    _syncMediaItem();
    _syncChapterQueue();
    _ignoreProgressPersistenceUntil =
        DateTime.now().add(const Duration(milliseconds: 1200));
    try {
      final media = await _mediaForChapter(book, _currentChapters[index]);
      await _player.open(media, play: false);
      await _player.play();
      await _waitForPlaybackClock(timeout: const Duration(seconds: 4));
      _finishPreparingPlayback();
    } catch (e, st) {
      isPreparingPlayback.value = false;
      debugPrint('AudiobookPlayerService.changeChapter: $e\n$st');
    }
  }

  int _playbackPositionMs() {
    if (isPreparingPlayback.value) {
      return _wallClockBase.inMilliseconds;
    }

    var bestMs = position.value.inMilliseconds;
    final fromPlayer = _player.state.position;
    if (fromPlayer > Duration.zero) {
      bestMs = fromPlayer.inMilliseconds > bestMs
          ? fromPlayer.inMilliseconds
          : bestMs;
    }
    if (isPlaying.value && _wallClockStartedAt != null) {
      var wall =
          _wallClockBase + DateTime.now().difference(_wallClockStartedAt!);
      final d = duration.value;
      if (d > Duration.zero && wall > d) wall = d;
      if (wall.inMilliseconds > bestMs) bestMs = wall.inMilliseconds;
    }
    if (bestMs < 0) return 0;
    return bestMs;
  }

  /// Chapter index clamped to the loaded chapter list + live player clock (for bookmarks).
  Future<({int chapterIndex, int positionMs})> captureBookmarkSnapshot() async {
    final n = _currentChapters.length;
    final idx = n == 0 ? 0 : currentChapterIndex.value.clamp(0, n - 1);
    var ms = _playbackPositionMs();
    if (ms < 0) ms = 0;

    final bid = currentBook.value?.audioBookId;
    if (bid != null && ms < 500) {
      final hist = await getHistory();
      for (final h in hist) {
        final b = h['book'];
        if (b is! Map || '${b['audioBookId']}' != bid) continue;
        final pCh = (h['chapterIndex'] as num?)?.toInt() ?? 0;
        final pMs = (h['positionMs'] as num?)?.toInt() ?? 0;
        if (idx == pCh && pMs > 60_000) {
          ms = pMs;
        }
        break;
      }
    }
    return (chapterIndex: idx, positionMs: ms);
  }

  // --- Persistence (History) ---

  Future<void> _saveProgress({bool force = false}) async {
    if (currentBook.value == null) return;
    if (!force) {
      if (_isResuming) return;
      final until = _ignoreProgressPersistenceUntil;
      if (until != null && DateTime.now().isBefore(until)) return;
    }
    final prefs = await SharedPreferences.getInstance();

    List<String> historyStrings =
        prefs.getStringList(AudiobookPrefsKeys.history) ?? [];
    List<Map<String, dynamic>> history = historyStrings
        .map((s) => json.decode(s) as Map<String, dynamic>)
        .toList();

    final bid = currentBook.value!.audioBookId;
    Map<String, dynamic>? prevSame;
    for (final item in history) {
      final b = item['book'];
      if (b is Map && '${b['audioBookId']}' == bid) {
        prevSame = item;
        break;
      }
    }

    int outCh = currentChapterIndex.value;
    int outMs = _playbackPositionMs();
    if (outMs < 0) outMs = 0;

    // Torrent / loopback streams sometimes leave the clock at 0 even while audio
    // is playing — carry forward the last saved offset for the same chapter.
    if (prevSame != null) {
      final pCh = (prevSame['chapterIndex'] as num?)?.toInt() ?? 0;
      final pMs = (prevSame['positionMs'] as num?)?.toInt() ?? 0;
      if (outCh == pCh) {
        if (outMs < 500 && pMs > 1_000) {
          outMs = pMs;
        } else if (outMs + 15_000 < pMs) {
          // Never regress saved progress on the same chapter.
          outMs = pMs;
        }
      }
    }

    final bookData = {
      'book': currentBook.value!.toJson(),
      'chapterIndex': outCh,
      'positionMs': outMs,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    history.removeWhere((item) {
      final b = item['book'];
      if (b is! Map) return false;
      return '${b['audioBookId']}' == bid;
    });
    history.insert(0, bookData);

    if (history.length > 10) history = history.sublist(0, 10);

    await prefs.setStringList(
      AudiobookPrefsKeys.history,
      history.map((e) => json.encode(e)).toList(),
    );
    PlaytorrioCloudSyncService.instance.scheduleDebouncedSettingsPush();
    SettingsService.notifyAudiobookPrefsChanged();
  }

  Future<void> saveManualProgress() async {
    await _saveProgress(force: true);
  }

  Future<List<Map<String, dynamic>>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> history = prefs.getStringList(AudiobookPrefsKeys.history) ?? [];
    return history.map((s) => json.decode(s) as Map<String, dynamic>).toList();
  }

  Future<void> resumeFromAndroidAuto(String audioBookId) async {
    final history = await getHistory();
    for (final progress in history) {
      final rawBook = progress['book'];
      if (rawBook is! Map) continue;
      if ('${rawBook['audioBookId']}' != audioBookId) continue;

      final book = Audiobook.fromJson(Map<String, dynamic>.from(rawBook));
      final ciRaw = progress['chapterIndex'];
      final chapterIndex = ciRaw is int
          ? ciRaw
          : (ciRaw is num ? ciRaw.toInt() : int.tryParse('$ciRaw') ?? 0);
      final pmRaw = progress['positionMs'];
      final positionMs = pmRaw is int
          ? pmRaw
          : (pmRaw is num ? pmRaw.toInt() : int.tryParse('$pmRaw') ?? 0);

      final prepared = await AudiobookService().prepareAudiobookPlayback(book);
      await loadBook(
        prepared.book,
        prepared.chapters,
        initialChapter: chapterIndex,
        resumePosition: Duration(milliseconds: positionMs),
      );
      return;
    }
    debugPrint(
      'AudiobookPlayerService: no history entry for Android Auto $audioBookId',
    );
  }

  Future<void> playChapterFromAndroidAuto(String audioBookId, int index) async {
    final book = currentBook.value;
    if (book != null && book.audioBookId == audioBookId) {
      await changeChapter(index);
      return;
    }

    final history = await getHistory();
    for (final progress in history) {
      final rawBook = progress['book'];
      if (rawBook is! Map) continue;
      if ('${rawBook['audioBookId']}' != audioBookId) continue;

      final histBook = Audiobook.fromJson(Map<String, dynamic>.from(rawBook));
      final prepared =
          await AudiobookService().prepareAudiobookPlayback(histBook);
      await loadBook(
        prepared.book,
        prepared.chapters,
        initialChapter: index,
      );
      return;
    }
    debugPrint(
      'AudiobookPlayerService: cannot play chapter for unknown book $audioBookId',
    );
  }

  void _syncChapterQueue() {
    final handler = _handler;
    final book = currentBook.value;
    if (handler == null || book == null || _currentChapters.isEmpty) return;

    final items = List<MediaItem>.generate(_currentChapters.length, (i) {
      final chapter = _currentChapters[i];
      var art = book.thumbUrl.trim();
      if (art.isEmpty) art = book.coverImage.trim();
      return MediaItem(
        id: AndroidAutoIds.chapter(book.audioBookId, i),
        album: book.title,
        title:
            chapter.title.isEmpty ? 'Chapter ${i + 1}' : chapter.title,
        artist: 'Stories',
        artUri: art.isEmpty ? null : Uri.tryParse(art),
      );
    });
    handler.queue.add(items);
  }

  Future<void> removeFromHistory(String audioBookId) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> historyStrings = prefs.getStringList(AudiobookPrefsKeys.history) ?? [];
    historyStrings.removeWhere((s) {
      final data = json.decode(s);
      return data['book']['audioBookId'] == audioBookId;
    });
    await prefs.setStringList(AudiobookPrefsKeys.history, historyStrings);
    PlaytorrioCloudSyncService.instance.scheduleSettingsPush();
    SettingsService.notifyAudiobookPrefsChanged();
  }

  // --- Liked Books ---

  Future<List<Audiobook>> getLikedBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> liked = prefs.getStringList(AudiobookPrefsKeys.liked) ?? [];
    return liked.map((s) => Audiobook.fromJson(json.decode(s))).toList();
  }

  Future<bool> isBookLiked(String audioBookId) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> liked = prefs.getStringList(AudiobookPrefsKeys.liked) ?? [];
    return liked.any((s) => json.decode(s)['audioBookId'] == audioBookId);
  }

  Future<void> toggleLikeBook(Audiobook book) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> likedStrings = prefs.getStringList(AudiobookPrefsKeys.liked) ?? [];
    
    final index = likedStrings.indexWhere((s) => json.decode(s)['audioBookId'] == book.audioBookId);
    
    if (index >= 0) {
      likedStrings.removeAt(index);
    } else {
      likedStrings.add(json.encode(book.toJson()));
    }
    
    await prefs.setStringList(AudiobookPrefsKeys.liked, likedStrings);
    PlaytorrioCloudSyncService.instance.scheduleSettingsPush();
    SettingsService.notifyAudiobookPrefsChanged();
  }

  // --- Bookmarks (synced via SettingsService → cloud when logged in) ---

  Future<void> _touchBookmarksRevision() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      AudiobookPrefsKeys.bookmarksUpdatedAt,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<List<Map<String, dynamic>>> getBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(AudiobookPrefsKeys.bookmarks) ?? [];
    final out = <Map<String, dynamic>>[];
    for (final s in raw) {
      try {
        final decoded = json.decode(s);
        if (decoded is Map) {
          out.add(Map<String, dynamic>.from(decoded as Map));
        }
      } catch (_) {}
    }
    return out;
  }

  Future<Set<String>> getBookmarkedAudioBookIds() async {
    final prefs = await SharedPreferences.getInstance();
    final strings = prefs.getStringList(AudiobookPrefsKeys.bookmarks) ?? [];
    final ids = <String>{};
    for (final s in strings) {
      try {
        final m = json.decode(s) as Map<String, dynamic>;
        final b = m['book'];
        if (b is Map && b['audioBookId'] != null) {
          ids.add('${b['audioBookId']}');
        }
      } catch (_) {}
    }
    return ids;
  }

  Future<bool> isBookmarked(String audioBookId) async {
    final ids = await getBookmarkedAudioBookIds();
    return ids.contains(audioBookId);
  }

  Future<void> removeBookmark(String audioBookId) async {
    final prefs = await SharedPreferences.getInstance();
    var strings = prefs.getStringList(AudiobookPrefsKeys.bookmarks) ?? [];
    strings.removeWhere((s) {
      try {
        final d = json.decode(s) as Map<String, dynamic>;
        final b = d['book'];
        if (b is Map) return '${b['audioBookId']}' == audioBookId;
      } catch (_) {}
      return false;
    });
    await prefs.setStringList(AudiobookPrefsKeys.bookmarks, strings);
    await _touchBookmarksRevision();
    PlaytorrioCloudSyncService.instance.scheduleSettingsPush();
    SettingsService.notifyAudiobookPrefsChanged();
  }

  /// Replace or insert bookmark for [book] (most recent first).
  Future<void> upsertBookmarkWithProgress(
    Audiobook book, {
    required int chapterIndex,
    required int positionMs,
    bool placeholderOnly = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    var strings = prefs.getStringList(AudiobookPrefsKeys.bookmarks) ?? [];
    strings.removeWhere((s) {
      try {
        final d = json.decode(s) as Map<String, dynamic>;
        final b = d['book'];
        if (b is Map) return '${b['audioBookId']}' == book.audioBookId;
      } catch (_) {}
      return false;
    });
    strings.insert(
      0,
      json.encode({
        'book': book.toJson(),
        'chapterIndex': chapterIndex,
        'positionMs': positionMs < 0 ? 0 : positionMs,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        if (placeholderOnly) 'placeholderBookmark': true,
      }),
    );
    await prefs.setStringList(AudiobookPrefsKeys.bookmarks, strings);
    await _touchBookmarksRevision();
    PlaytorrioCloudSyncService.instance.scheduleSettingsPush();
    SettingsService.notifyAudiobookPrefsChanged();
  }

  /// From grid: add bookmark without a saved position, or remove if already present.
  Future<void> toggleBookmarkGrid(Audiobook book) async {
    if (await isBookmarked(book.audioBookId)) {
      await removeBookmark(book.audioBookId);
    } else {
      await upsertBookmarkWithProgress(
        book,
        chapterIndex: 0,
        positionMs: 0,
        placeholderOnly: true,
      );
    }
  }

  void dispose() {
    _progressSaveDebounce?.cancel();
    for (var s in _subscriptions) { s.cancel(); }
    _player.dispose();
  }
}
