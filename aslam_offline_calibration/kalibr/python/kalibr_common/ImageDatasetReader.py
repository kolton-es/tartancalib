import cv2
import os
import numpy as np
import aslam_cv as acv
import sm


IMAGE_EXTENSIONS = ('.png', '.jpg', '.jpeg', '.bmp', '.tif', '.tiff')


class FolderImageDatasetReaderIterator(object):
  def __init__(self, dataset, indices=None):
    self.dataset = dataset
    if indices is None:
      self.indices = np.arange(dataset.numImages())
    else:
      self.indices = indices
    self.iter = self.indices.__iter__()

  def __iter__(self):
    return self

  def next(self):
    # required for python 2.x compatibility
    idx = next(self.iter)
    return self.dataset.getImage(idx)

  def __next__(self):
    idx = next(self.iter)
    return self.dataset.getImage(idx)


class FolderImageDatasetReader(object):
  """Reads one camera's images from a folder.

  Every image is named by its timestamp in integer nanoseconds, e.g.
  1700000000250000000.png (the layout Kalibr's bag creator used):

    dataset/cam0/<timestamp_ns>.png
    dataset/cam1/<timestamp_ns>.png
  """

  def __init__(self, folder, from_to=None):
    self.folder = folder
    # Name used in logs and as the camchain "rostopic" field.
    self.topic = os.path.basename(os.path.normpath(folder))
    if not os.path.isdir(folder):
      raise RuntimeError("Image folder {0} does not exist.".format(folder))

    entries = list()
    for f in os.listdir(folder):
      stem, ext = os.path.splitext(f)
      if ext.lower() not in IMAGE_EXTENSIONS:
        continue
      if not stem.isdigit():
        raise RuntimeError(
            "Image {0} in {1} is not named <timestamp_ns>{2}.".format(f, folder, ext))
      entries.append((int(stem), os.path.join(folder, f)))
    if not entries:
      raise RuntimeError("No images found in {0}.".format(folder))

    # sort by timestamp
    entries.sort()
    self.timestamps_ns = [e[0] for e in entries]
    self.files = [e[1] for e in entries]
    self.indices = np.arange(len(self.files))

    # remove the images outside the timespan [start + from, start + to]
    if from_to:
      self.indices = self.truncateIndicesFromTime(self.indices, from_to)

  def truncateIndicesFromTime(self, indices, from_to):
    timestamps = [self.timestamps_ns[idx] / 1.0e9 for idx in indices]

    start = min(timestamps)
    length = max(timestamps) - start

    # some value checking
    if from_to[0] >= from_to[1]:
      raise RuntimeError("Start time must be smaller than end time.")
    if from_to[0] < 0.0:
      sm.logWarn("Start time of {0} s is smaller 0".format(from_to[0]))
    if from_to[1] > length:
      sm.logWarn("End time of {0} s is bigger than the total length of {1} s".format(
          from_to[1], length))

    # find the valid timestamps
    valid_indices = []
    for idx, timestamp in zip(indices, timestamps):
      if timestamp >= (start + from_to[0]) and timestamp <= (start + from_to[1]):
        valid_indices.append(idx)
    sm.logWarn(
        "FolderImageDatasetReader: truncated {0} / {1} images.".format(len(indices) - len(valid_indices), len(indices)))
    return np.array(valid_indices)

  def __iter__(self):
    return self.readDataset()

  def readDataset(self):
    return FolderImageDatasetReaderIterator(self, self.indices)

  def readDatasetShuffle(self):
    indices = self.indices
    np.random.shuffle(indices)
    return FolderImageDatasetReaderIterator(self, indices)

  def numImages(self):
    return len(self.indices)

  def getImage(self, idx):
    stamp_ns = self.timestamps_ns[idx]
    timestamp = acv.Time(stamp_ns // 1000000000, stamp_ns % 1000000000)

    img_data = cv2.imread(self.files[idx], cv2.IMREAD_UNCHANGED)
    if img_data is None:
      raise RuntimeError("Could not read image {0}.".format(self.files[idx]))
    if img_data.dtype == np.uint16:
      img_data = (img_data / 256).astype("uint8")
    if img_data.ndim == 3 and img_data.shape[2] == 4:
      img_data = cv2.cvtColor(img_data, cv2.COLOR_BGRA2GRAY)
    elif img_data.ndim == 3 and img_data.shape[2] == 3:
      img_data = cv2.cvtColor(img_data, cv2.COLOR_BGR2GRAY)
    elif img_data.ndim != 2:
      raise RuntimeError("Unsupported image layout {0} in {1}.".format(img_data.shape, self.files[idx]))
    return (timestamp, img_data)
