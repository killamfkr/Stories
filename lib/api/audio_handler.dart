import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:media_kit/media_kit.dart' as mk;

import 'audiobook_player_service.dart';
import 'music_player_service.dart';
import 'android_auto_browse.dart';

enum AudioPlayerType { music, audiobook }

class PlayTorrioAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final mk.Player _musicPlayer;
  AudioPlayerType _currentType = AudioPlayerType.music;
  dynamic _activePlayer;

  PlayTorrioAudioHandler(this._musicPlayer) {
    _activePlayer = _musicPlayer;
    _musicPlayer.stream.position.listen((_) => _updateMusicState());
    _musicPlayer.stream.playing.listen((_) => _updateMusicState());
    _musicPlayer.stream.buffering.listen((_) => _updateMusicState());
  }

  void setPlayerType(AudioPlayerType type, dynamic player) {
    _currentType = type;
    _activePlayer = player;

    if (type == AudioPlayerType.audiobook) {
      AudiobookPlayerService().publishNowPlaying();
      return;
    }

    if (type == AudioPlayerType.music) {
      _updateMusicState();
    }
  }

  void _updateMusicState() {
    if (_currentType != AudioPlayerType.music) return;
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        _musicPlayer.state.playing ? MediaControl.pause : MediaControl.play,
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
      processingState: _musicPlayer.state.buffering
          ? AudioProcessingState.buffering
          : AudioProcessingState.ready,
      playing: _musicPlayer.state.playing,
      updatePosition: _musicPlayer.state.position,
      bufferedPosition: _musicPlayer.state.buffer,
      speed: _musicPlayer.state.rate,
    ));
  }

  @override
  Future<void> play() async {
    if (_currentType == AudioPlayerType.music) {
      MusicPlayerService().play();
    } else {
      await (_activePlayer as mk.Player).play();
      AudiobookPlayerService().publishNowPlaying();
    }
  }

  @override
  Future<void> pause() async {
    if (_currentType == AudioPlayerType.music) {
      MusicPlayerService().pause();
    } else {
      await (_activePlayer as mk.Player).pause();
      AudiobookPlayerService().publishNowPlaying();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    if (_currentType == AudioPlayerType.music) {
      await _musicPlayer.seek(position);
    } else {
      await AudiobookPlayerService().seekTo(position);
    }
  }

  @override
  Future<void> skipToNext() async {
    if (_currentType == AudioPlayerType.music) {
      MusicPlayerService().next();
    } else {
      AudiobookPlayerService().skipToNextChapter();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_currentType == AudioPlayerType.music) {
      MusicPlayerService().previous();
    } else {
      AudiobookPlayerService().skipToPreviousChapter();
    }
  }

  void updateState(PlaybackState state) {
    if (_currentType == AudioPlayerType.audiobook) {
      playbackState.add(state);
    }
  }

  @override
  Future<void> updateMediaItem(MediaItem mediaItem) async {
    this.mediaItem.add(mediaItem);
  }

  @override
  Future<void> stop() async {
    if (_currentType == AudioPlayerType.music) {
      await _musicPlayer.stop();
    } else {
      await AudiobookPlayerService().stop();
    }
    return super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    await stop();
    await super.onTaskRemoved();
  }

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) {
    return AndroidAutoBrowse.childrenFor(parentMediaId);
  }

  @override
  Future<void> playFromMediaId(String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    await AndroidAutoBrowse.playMediaId(mediaId);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (_currentType == AudioPlayerType.audiobook) {
      await AudiobookPlayerService().changeChapter(index);
      return;
    }
    await super.skipToQueueItem(index);
  }
}
