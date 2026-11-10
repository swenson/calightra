// SPDX-License-Identifier: Apache-2.0

use caliptra_auth_man_gen::{
    AuthManifestGenerator, AuthManifestGeneratorConfig, AuthManifestGeneratorKeyConfig,
};
use caliptra_auth_man_types::{
    Addr64, AuthManifestFlags, AuthManifestImageMetadata, AuthManifestPrivKeysConfig,
    AuthManifestPubKeysConfig, ImageMetadataFlags,
};
use caliptra_image_crypto::RustCrypto as Crypto;
use caliptra_image_fake_keys::*;
use caliptra_image_gen::{from_hw_format, ImageGeneratorCrypto};
use caliptra_image_types::FwVerificationPqcKeyType;
use zerocopy::IntoBytes;

const MCU_RT_IDENTIFIER: u32 = 2;
const V_AUTH_KEY_ID: u32 = 4;
const IMAGE_SOURCE_IN_REQUEST: u32 = 1;

const VENDOR_AUTH_KEY_ANCHOR: [u8; 48] = [
    0xa2, 0x68, 0x7c, 0xf2, 0x45, 0x99, 0xb8, 0xf0, 0xf8, 0x26, 0x81, 0xd9, 0xbf, 0x6d, 0x77, 0xac,
    0x22, 0x47, 0x09, 0x4d, 0x1e, 0x9a, 0x2d, 0x81, 0x41, 0x55, 0x5f, 0xc6, 0x0d, 0x05, 0xc3, 0x0a,
    0x9f, 0xbd, 0x23, 0x46, 0x18, 0x09, 0xbf, 0xa5, 0x7d, 0xc7, 0x28, 0xd7, 0xbc, 0xc1, 0x7d, 0xea,
];

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("Usage: {} <mcu_rt.bin> <soc_manifest.bin>", args[0]);
        std::process::exit(1);
    }
    let mcu_rt_path = &args[1];
    let out_path = &args[2];

    let data = std::fs::read(mcu_rt_path).expect("Failed to read mcu_rt.bin");
    let crypto = Crypto::default();
    let digest = from_hw_format(&crypto.sha384_digest(&data).expect("SHA-384 failed"));

    let mut flags = ImageMetadataFlags(0);
    flags.set_image_source(IMAGE_SOURCE_IN_REQUEST);
    flags.set_exec_bit(2);

    let mcu_metadata = AuthManifestImageMetadata {
        fw_id: MCU_RT_IDENTIFIER,
        flags: flags.0,
        digest,
        image_load_address: Addr64 {
            lo: 0x21c0_0000,
            hi: 0,
        },
        image_staging_address: Addr64 {
            lo: 0xB000_0000,
            hi: 0,
        },
        component_id: MCU_RT_IDENTIFIER,
        ..Default::default()
    };

    let vendor_auth_key_metadata = AuthManifestImageMetadata {
        fw_id: V_AUTH_KEY_ID,
        flags: 0,
        component_id: V_AUTH_KEY_ID,
        digest: VENDOR_AUTH_KEY_ANCHOR,
        ..Default::default()
    };

    let vendor_fw_key_info = AuthManifestGeneratorKeyConfig {
        pub_keys: AuthManifestPubKeysConfig {
            ecc_pub_key: VENDOR_ECC_KEY_0_PUBLIC,
            lms_pub_key: VENDOR_LMS_KEY_0_PUBLIC,
            mldsa_pub_key: VENDOR_MLDSA_KEY_0_PUBLIC,
        },
        priv_keys: Some(AuthManifestPrivKeysConfig {
            ecc_priv_key: VENDOR_ECC_KEY_0_PRIVATE,
            lms_priv_key: VENDOR_LMS_KEY_0_PRIVATE,
            mldsa_priv_key: VENDOR_MLDSA_KEY_0_PRIVATE,
        }),
    };

    let vendor_man_key_info = AuthManifestGeneratorKeyConfig {
        pub_keys: AuthManifestPubKeysConfig {
            ecc_pub_key: VENDOR_ECC_KEY_1_PUBLIC,
            lms_pub_key: VENDOR_LMS_KEY_1_PUBLIC,
            mldsa_pub_key: VENDOR_MLDSA_KEY_0_PUBLIC,
        },
        priv_keys: Some(AuthManifestPrivKeysConfig {
            ecc_priv_key: VENDOR_ECC_KEY_1_PRIVATE,
            lms_priv_key: VENDOR_LMS_KEY_1_PRIVATE,
            mldsa_priv_key: VENDOR_MLDSA_KEY_0_PRIVATE,
        }),
    };

    let owner_key_info = AuthManifestGeneratorKeyConfig {
        pub_keys: AuthManifestPubKeysConfig {
            ecc_pub_key: OWNER_ECC_KEY_PUBLIC,
            lms_pub_key: OWNER_LMS_KEY_PUBLIC,
            mldsa_pub_key: OWNER_MLDSA_KEY_PUBLIC,
        },
        priv_keys: Some(AuthManifestPrivKeysConfig {
            ecc_priv_key: OWNER_ECC_KEY_PRIVATE,
            lms_priv_key: OWNER_LMS_KEY_PRIVATE,
            mldsa_priv_key: OWNER_MLDSA_KEY_PRIVATE,
        }),
    };

    let gen_config = AuthManifestGeneratorConfig {
        vendor_fw_key_info: Some(vendor_fw_key_info),
        vendor_man_key_info: Some(vendor_man_key_info),
        owner_fw_key_info: Some(owner_key_info.clone()),
        owner_man_key_info: Some(owner_key_info),
        image_metadata_list: vec![mcu_metadata, vendor_auth_key_metadata],
        version: 1,
        flags: AuthManifestFlags::VENDOR_SIGNATURE_REQUIRED,
        pqc_key_type: FwVerificationPqcKeyType::MLDSA,
        svn: 1,
    };

    let gen = AuthManifestGenerator::new(Crypto::default());
    let manifest = gen.generate(&gen_config).expect("Manifest generation failed");
    std::fs::write(out_path, manifest.as_bytes()).expect("Failed to write soc_manifest.bin");
    println!(
        "Generated {} ({} bytes, MLDSA-87 + ECC-384 signed) for {} ({} bytes)",
        out_path,
        manifest.as_bytes().len(),
        mcu_rt_path,
        data.len()
    );
}
