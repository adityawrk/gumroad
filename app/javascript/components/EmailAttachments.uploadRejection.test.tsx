// @vitest-environment happy-dom
import { act, cleanup, renderHook } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

import {
  FileState,
  filesReducer,
  FilesDispatchProvider,
  isFileUploading,
  useUploadFiles,
} from "$app/components/EmailAttachments";
import { EvaporateUploaderProvider } from "$app/components/EvaporateUploader";
import { S3UploadConfigProvider } from "$app/components/S3UploadConfig";
import { useConfigureEvaporate } from "$app/components/useConfigureEvaporate";

const alerts = vi.hoisted(() => vi.fn());
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: alerts }));

vi.stubGlobal("Routes", {
  s3_utility_generate_multipart_signature_path: () => "/s3/signature",
  s3_utility_current_utc_time_string_path: () => "/s3/time",
});

afterEach(() => {
  cleanup();
  alerts.mockReset();
  vi.clearAllTimers();
  vi.useRealTimers();
});

beforeEach(() => vi.useFakeTimers());

const MAX_FILE_SIZE = 20 * 1024 * 1024 * 1024;
const sizedFile = (name: string, size: number): File => {
  const file = new File(["x"], name, { type: "video/mp4" });
  // The uploader checks metadata before reading a file, so no 20 GB allocation is needed.
  Object.defineProperty(file, "size", { value: size });
  return file;
};

const renderUploader = () => {
  let files: FileState[] = [];
  const { result } = renderHook(() => useUploadFiles(), {
    wrapper: ({ children }: { children: React.ReactNode }) => {
      const { evaporateUploader, s3UploadConfig } = useConfigureEvaporate({
        aws_access_key_id: "example-key",
        s3_url: "https://s3.example.com/bucket",
        user_id: "example-seller",
      });
      const [state, dispatch] = React.useReducer(filesReducer, []);
      files = state;
      return (
        <EvaporateUploaderProvider value={evaporateUploader}>
          <S3UploadConfigProvider value={s3UploadConfig}>
            <FilesDispatchProvider value={dispatch}>{children}</FilesDispatchProvider>
          </S3UploadConfigProvider>
        </EvaporateUploaderProvider>
      );
    },
  });
  if (!result.current) throw new Error("uploader hook returned null");
  return { upload: result.current, getFiles: () => files };
};

it("removes an attachment rejected by the real uploader's 20 GB limit so saving is unblocked", () => {
  const { upload, getFiles } = renderUploader();

  act(() => upload("email-1", [sizedFile("large-video.mp4", MAX_FILE_SIZE + 1)]));

  expect(alerts).toHaveBeenCalledExactlyOnceWith("File size too large. Maximum size allowed is 20 Gb", "error");
  expect(getFiles().some(isFileUploading)).toBe(false);
  expect(getFiles()).toEqual([]);
});

it("keeps an accepted attachment when other files in the batch exceed the limit", () => {
  const { upload, getFiles } = renderUploader();

  act(() =>
    upload("email-1", [
      sizedFile("large-first.mp4", MAX_FILE_SIZE + 1),
      sizedFile("accepted.mp4", MAX_FILE_SIZE),
      sizedFile("large-last.mp4", MAX_FILE_SIZE + 1),
    ]),
  );

  expect(getFiles()).toHaveLength(1);
  expect(getFiles()[0]).toMatchObject({ file_name: "accepted", email_id: "email-1" });
  expect(alerts).toHaveBeenCalledTimes(2);
});

it("allows selecting a smaller replacement without retaining the rejected file or removing another email's file", () => {
  const { upload, getFiles } = renderUploader();
  act(() => upload("other-email", [sizedFile("other.mp4", 1)]));
  act(() => upload("email-1", [sizedFile("replacement.mp4", MAX_FILE_SIZE + 1)]));
  act(() => upload("email-1", [sizedFile("replacement.mp4", 1)]));

  expect(getFiles().map(({ email_id, file_name }) => ({ email_id, file_name }))).toEqual([
    { email_id: "other-email", file_name: "other" },
    { email_id: "email-1", file_name: "replacement" },
  ]);
  expect(alerts).toHaveBeenCalledTimes(1);
});
